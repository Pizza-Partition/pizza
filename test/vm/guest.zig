//! Common CLI-driven acceptance workflow. Native disk admission, setup,
//! filesystem access and plan edits belong to the guest's platform adapter.
const std = @import("std");
const u = @import("vm_common");
const proto = @import("proto");
const w = proto.wire;
const editor = @import("core/planning/editor.zig");
pub const Layout = struct { uuid: ?[]const u8, offset: []const u8, length: []const u8, type_guid: ?[]const u8, attributes: ?[]const u8, slot: ?u32, filesystem: ?w.FilesystemKind, name: []const u8 };
const Other = struct { identity: ?[]const u8, layout: []Layout };
const Expected = struct { before: []Layout, after: []const w.DesiredPartition, unrelated: []Other, hash: []const u8, disk_identity: []const u8, digest: []const u8 };
pub fn Guest(comptime Platform: type) type {
    return struct {
        const Self = @This();
        a: std.mem.Allocator,
        io: std.Io,
        work: []const u8,
        serial: []const u8,
        wwn: []const u8,
        case: []const u8,
        native: Platform = .{},
        pub fn target(g: Self, inventory: w.InventorySnapshot) !w.HostDisk {
            return Platform.target(g, inventory);
        }
        pub fn fileHash(g: Self, disk: w.HostDisk) ![]const u8 {
            return Platform.fileHash(g, disk);
        }
        pub fn path(g: Self, filename: []const u8) ![]const u8 {
            return std.fs.path.join(g.a, &.{ g.work, filename });
        }
        pub fn name(g: Self, suffix: []const u8) ![]const u8 {
            return g.a.print("{s}-{s}", .{ g.case, suffix });
        }
        pub fn save(g: Self, name_: []const u8, value: anytype) !void {
            try std.Io.Dir.cwd().writeFile(g.io, .{ .sub_path = try g.path(name_), .data = try std.json.Stringify.valueAlloc(g.a, value, .{ .whitespace = .indent_2 }) });
        }
        pub fn load(g: Self, comptime T: type, name_: []const u8) !T {
            return std.json.parseFromSliceLeaky(T, g.a, try std.Io.Dir.cwd().readFileAlloc(g.io, try g.path(name_), g.a, .limited(512 * 1024 * 1024)), .{});
        }
        pub fn program(g: Self, name_: []const u8, argv: []const []const u8, input: ?[]const u8) ![]const u8 {
            const r = try u.runAt(g.a, g.io, null, .inherit, argv, input, 600);
            try std.Io.Dir.cwd().writeFile(g.io, .{ .sub_path = try g.path(try g.a.print("{s}.stdout", .{name_})), .data = r.stdout });
            try std.Io.Dir.cwd().writeFile(g.io, .{ .sub_path = try g.path(try g.a.print("{s}.stderr", .{name_})), .data = r.stderr });
            return u.check(r);
        }
        pub fn pizza(g: Self, comptime T: type, command: []const u8, input: anytype, suffix: []const u8) !T {
            const name_ = try g.name(suffix);
            const bytes: ?[]const u8 = if (@TypeOf(input) == @TypeOf(null)) null else try std.json.Stringify.valueAlloc(g.a, input, .{ .whitespace = .indent_2 });
            if (bytes) |b| try std.Io.Dir.cwd().writeFile(g.io, .{ .sub_path = try g.path(try g.a.print("{s}.input.json", .{name_})), .data = b });
            const output = try g.program(name_, &.{ try g.path("pizza-backend" ++ Platform.extension), command }, bytes);
            try std.Io.Dir.cwd().writeFile(g.io, .{ .sub_path = try g.path(try g.a.print("{s}.json", .{name_})), .data = output });
            return std.json.parseFromSliceLeaky(T, g.a, output, .{});
        }
        pub fn snapshot(g: Self) !w.InventorySnapshot {
            return g.pizza(w.InventorySnapshot, "inventory", null, "inventory");
        }
        pub fn plan(g: Self) !void {
            const inventory = try g.snapshot();
            const disk = try g.target(inventory);
            var request: editor.Request = .{ .version = inventory.version, .snapshot_id = inventory.snapshot_id, .disk_identity = disk.identity orelse return error.IdentityMissing };
            const initial = try g.pizza(editor.Result, "plan", request, "initial");
            const result = try Platform.edit(g, &request, initial);
            const validated = result.validated orelse return error.ValidationMissing;
            if (!validated.offline_validation_required or validated.maintenance_operations.len == 0) return error.MaintenanceNotExercised;
            for (validated.diagnostics) |diag| if (diag.severity == .@"error") return error.InvalidPlan;
            var others: std.ArrayList(Other) = .empty;
            for (inventory.disks) |other| if (!std.mem.eql(u8, other.identity orelse "", disk.identity.?)) try others.append(g.a, .{ .identity = other.identity, .layout = try layouts(g.a, other) });
            try g.save(try g.name("expected.json"), Expected{ .before = try layouts(g.a, disk), .after = result.draft.layout, .unrelated = others.items, .hash = try g.fileHash(disk), .disk_identity = disk.identity.?, .digest = validated.digest });
        }
        pub fn verify(g: Self) !void {
            const expected = try g.load(Expected, try g.name("expected.json"));
            const prepared = try g.load(w.MaintenanceSession, try g.name("prepared.json"));
            const receipt = try g.pizza(w.CompletionReceipt, "complete-session", null, "receipt");
            const again = try g.pizza(w.CompletionReceipt, "complete-session", null, "receipt-again");
            try equal(g.a, receipt, again);
            if (!std.mem.eql(u8, receipt.id, prepared.id) or !std.mem.eql(u8, receipt.plan_digest, expected.digest) or !std.mem.eql(u8, receipt.disk_identity, expected.disk_identity)) return error.ReceiptBindingChanged;
            const accept = @import("vm_common").cases.accepts(g.case);
            if (receipt.outcome != @as(@TypeOf(receipt.outcome), if (accept) .completed else .rolled_back)) return error.UnexpectedOutcome;
            const s = try g.snapshot();
            const d = try g.target(s);
            const hash = try g.fileHash(d);
            if (!std.mem.eql(u8, hash, expected.hash)) return error.SentinelHashChanged;
            for (expected.unrelated) |other| {
                var found = false;
                for (s.disks) |disk| if (std.mem.eql(u8, disk.identity orelse "", other.identity orelse "")) {
                    try equal(g.a, other.layout, try layouts(g.a, disk));
                    found = true;
                    break;
                };
                if (!found) return error.UnrelatedDiskMissing;
            }
            const after = try layouts(g.a, d);
            try verifyLayout(g.a, expected.before, expected.after, after, accept);
            try g.save(try g.name("verify.json"), .{ .case = g.case, .outcome = receipt.outcome, .id = receipt.id, .hash = hash, .receipt = receipt, .idempotent = true });
        }
        pub fn prepare(g: Self) !void {
            const plan_ = try g.load(editor.Result, try g.name("plan.json"));
            const prepared = try g.pizza(w.MaintenanceSession, "request", w.PrivilegedRequest{ .version = proto.API_VERSION, .action = .prepare, .draft = plan_.draft, .approved_digest = plan_.validated.?.digest }, "prepared");
            if (prepared.phase != .prepared or !std.mem.eql(u8, prepared.plan_digest, plan_.validated.?.digest)) return error.PreparationMismatch;
        }
        pub fn reboot(g: Self) !void {
            const prepared = try g.load(w.MaintenanceSession, try g.name("prepared.json"));
            _ = try g.pizza(w.MaintenanceSession, "request", w.PrivilegedRequest{ .version = proto.API_VERSION, .action = .reboot, .session_id = prepared.id, .approved_digest = prepared.plan_digest }, "reboot");
        }
        pub fn runNative(g: Self) !void {
            inline for (.{ "domain", "protocol", "host", "image" }) |suite| _ = try g.program(suite, &.{try g.path(Platform.test_dir ++ "/" ++ suite ++ "-tests" ++ Platform.extension)}, null);
        }
        pub fn collect(g: Self) !void {
            var dir = try std.Io.Dir.cwd().openDir(g.io, g.work, .{ .iterate = true });
            defer dir.close(g.io);
            var it = dir.iterate();
            while (try it.next(g.io)) |entry| {
                if (entry.kind != .file or !(std.mem.endsWith(u8, entry.name, ".json") or std.mem.endsWith(u8, entry.name, ".stdout") or std.mem.endsWith(u8, entry.name, ".stderr"))) continue;
                const bytes = try std.Io.Dir.cwd().readFileAlloc(g.io, try g.path(entry.name), g.a, .limited(512 * 1024 * 1024));
                const enc = std.base64.standard.Encoder;
                const output = try g.a.alloc(u8, enc.calcSize(bytes.len));
                try std.Io.File.stdout().writeStreamingAll(g.io, try g.a.print("PZ_FILE:{s}:{s}\n", .{ entry.name, enc.encode(output, bytes) }));
            }
        }
    };
}
pub fn layouts(a: std.mem.Allocator, d: w.HostDisk) ![]Layout {
    const result = try a.alloc(Layout, d.partitions.len);
    for (d.partitions, 0..) |p, i| result[i] = .{ .uuid = p.partition_uuid, .offset = p.offset, .length = p.length, .type_guid = p.type_guid, .attributes = p.attributes, .slot = p.slot, .filesystem = p.filesystem, .name = p.name };
    std.mem.sort(Layout, result, {}, struct {
        fn less(_: void, x: Layout, y: Layout) bool {
            return (proto.byteCount(x.offset) catch 0) < (proto.byteCount(y.offset) catch 0);
        }
    }.less);
    return result;
}
pub fn equal(a: std.mem.Allocator, x: anytype, y: anytype) !void {
    const left = try std.json.Stringify.valueAlloc(a, x, .{ .whitespace = .indent_2 });
    defer a.free(left);
    const right = try std.json.Stringify.valueAlloc(a, y, .{ .whitespace = .indent_2 });
    defer a.free(right);
    if (!std.mem.eql(u8, left, right)) return error.PostconditionMismatch;
}

test {
    _ = u.cases;
}

/// Accept must match the whole approved layout; Undo must match the whole original.
/// An omitted desired slot allows the executor to choose a free GPT entry.
pub fn verifyLayout(a: std.mem.Allocator, before: []const Layout, desired: []const w.DesiredPartition, after: []const Layout, accept: bool) !void {
    if (!accept) return equal(a, before, after);
    if (after.len != desired.len) return error.UnexpectedPartitionCount;
    for (desired) |wanted| {
        var found = false;
        for (after) |actual| if (std.mem.eql(u8, actual.uuid orelse "", wanted.partition_uuid orelse return error.MissingPartitionIdentity)) {
            const expected: Layout = .{ .uuid = wanted.partition_uuid, .offset = wanted.offset, .length = wanted.length, .type_guid = wanted.type_guid, .attributes = wanted.attributes, .slot = wanted.slot orelse actual.slot orelse return error.MissingPartitionSlot, .filesystem = wanted.filesystem, .name = wanted.name };
            try equal(a, expected, actual);
            found = true;
            break;
        };
        if (!found) return error.ApprovedPartitionMissing;
    }
}

test "accept requires the entire approved layout; undo requires the original" {
    const a = std.testing.allocator;
    const old: Layout = .{ .uuid = "11111111111111111111111111111111", .offset = "1048576", .length = "536870912", .type_guid = "22222222222222222222222222222222", .attributes = "0", .slot = 1, .filesystem = .ext4, .name = "Keep" };
    const wanted: w.DesiredPartition = .{ .id = "partition", .partition_uuid = old.uuid, .offset = "68157440", .length = old.length, .type_guid = old.type_guid, .attributes = old.attributes.?, .slot = old.slot, .filesystem = old.filesystem, .name = old.name, .retain_data = true };
    var moved = old;
    moved.offset = wanted.offset;
    try verifyLayout(a, &.{old}, &.{wanted}, &.{moved}, true);
    try verifyLayout(a, &.{old}, &.{wanted}, &.{old}, false);
    try std.testing.expectError(error.PostconditionMismatch, verifyLayout(a, &.{old}, &.{wanted}, &.{moved}, false));
    try std.testing.expectError(error.PostconditionMismatch, verifyLayout(a, &.{old}, &.{wanted}, &.{old}, true));
    var changed = moved;
    changed.slot = 2;
    try std.testing.expectError(error.PostconditionMismatch, verifyLayout(a, &.{old}, &.{wanted}, &.{changed}, true));
    try std.testing.expectError(error.UnexpectedPartitionCount, verifyLayout(a, &.{old}, &.{wanted}, &.{}, true));
}
test "new partitions may choose a slot but must retain approved identity and metadata" {
    const a = std.testing.allocator;
    const wanted: w.DesiredPartition = .{ .id = "new", .partition_uuid = "33333333333333333333333333333333", .offset = "1107296256", .length = "268435456", .type_guid = "22222222222222222222222222222222", .attributes = "0", .filesystem = .ntfs, .name = "New", .retain_data = false };
    var actual: Layout = .{ .uuid = wanted.partition_uuid, .offset = wanted.offset, .length = wanted.length, .type_guid = wanted.type_guid, .attributes = wanted.attributes, .slot = 3, .filesystem = wanted.filesystem, .name = wanted.name };
    try verifyLayout(a, &.{}, &.{wanted}, &.{actual}, true);
    actual.name = "Foreign";
    try std.testing.expectError(error.PostconditionMismatch, verifyLayout(a, &.{}, &.{wanted}, &.{actual}, true));
    actual.uuid = "44444444444444444444444444444444";
    try std.testing.expectError(error.ApprovedPartitionMissing, verifyLayout(a, &.{}, &.{wanted}, &.{actual}, true));
}
