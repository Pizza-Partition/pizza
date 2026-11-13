const std = @import("std");
const proto = @import("proto");
const wire = @import("proto").wire;
const MIB = 1024 * 1024;
fn fixture() struct { disk: wire.HostDisk, inventory: wire.InventorySnapshot } {
    return .{ .disk = .{ .path = "/dev/disposable", .identity = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .capacity = "10485760", .sector_size = 512, .model = "fixture", .read_only = false, .partition_table = "gpt", .usable_offset = "1048576", .usable_length = "8388608", .partitions = &.{.{ .id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .offset = "1048576", .length = "6291456", .name = "", .filesystem = .ext4, .encryption = .none, .path = "/dev/disposable1", .capabilities = &.{.{ .operation = .resize, .backend = .host, .support = .available, .reason = "fixture", .grow = true, .shrink = true }} }} }, .inventory = .{ .version = proto.API_VERSION, .snapshot_id = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .platform = .linux } };
}
test "host scheduler shrinks before creating in the released range" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fixture();
    f.inventory.disks = &.{f.disk};
    const id = f.disk.partitions[0].id;
    const new_id = try @import("../../core/planning/identity.zig").partition(a, f.disk.identity.?, "11111111111111111111111111111111");
    const draft: wire.PlanDraft = .{ .version = proto.API_VERSION, .snapshot_id = f.inventory.snapshot_id, .disk_identity = f.disk.identity.?, .intents = &.{ .{ .kind = .create, .partition_id = new_id, .offset = "5242880", .length = "2097152", .filesystem = .ext4 }, .{ .kind = .resize, .partition_id = id, .length = "4194304" } }, .layout = &.{ .{ .id = id, .offset = "1048576", .length = "4194304", .name = f.disk.partitions[0].name, .filesystem = .ext4 }, .{ .id = new_id, .offset = "5242880", .length = "2097152", .name = "New", .filesystem = .ext4, .retain_data = false, .type_guid = "af3dc60f838472478e793d69d8477de4", .partition_uuid = "11111111111111111111111111111111" } } };
    const result = try @import("../../core/planning/planner.zig").validate(a, f.inventory, draft, Capabilities{});
    try std.testing.expect(result.executable);
    try std.testing.expectEqual(@as(usize, 2), result.host_operations.len);
    try std.testing.expectEqual(.resize, result.host_operations[0].kind);
    try std.testing.expectEqual(.create, result.host_operations[1].kind);

    // The same reviewed plan must become non-executable when the supplied
    // platform cannot perform its filesystem operations.
    const unavailable = try @import("../../core/planning/planner.zig").validate(a, f.inventory, draft, Capabilities{ .available = false });
    try std.testing.expect(!unavailable.executable);
    try std.testing.expectEqual(@as(usize, 0), unavailable.host_operations.len);
    try std.testing.expectEqual(@as(usize, 2), unavailable.maintenance_operations.len);
    try std.testing.expectEqualStrings(result.digest, unavailable.digest);
    const invalid_label = try @import("../../core/planning/planner.zig").validate(a, f.inventory, draft, Capabilities{ .label_valid = false });
    try std.testing.expect(!invalid_label.executable);
    for (invalid_label.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "filesystem_label_rejected")) return;
    }
    return error.MissingLabelDiagnostic;
}
test "stale baseline and encrypted volumes cannot execute" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fixture();
    var partitions = try a.dupe(wire.HostPartition, f.disk.partitions);
    partitions[0].encryption = .encrypted;
    f.disk.partitions = partitions;
    f.inventory.disks = &.{f.disk};
    const draft: wire.PlanDraft = .{ .version = proto.API_VERSION, .snapshot_id = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .disk_identity = f.disk.identity.?, .intents = &.{.{ .kind = .delete, .partition_id = partitions[0].id }} };
    const result = try @import("../../core/planning/planner.zig").validate(a, f.inventory, draft, Capabilities{});
    try std.testing.expect(!result.executable);
    var stale = false;
    var encrypted = false;
    for (result.diagnostics) |d| {
        stale = stale or std.mem.eql(u8, d.code, "stale_inventory");
        encrypted = encrypted or std.mem.eql(u8, d.code, "protected_partition");
    }
    try std.testing.expect(stale and encrypted);
}

pub const Capabilities = struct {
    available: bool = true,
    label_valid: bool = true,
    pub fn validLabel(self: Capabilities, _: std.mem.Allocator, _: wire.FilesystemKind, _: []const u8) !bool {
        return self.label_valid;
    }
    pub fn canFs(self: Capabilities, _: std.mem.Allocator, _: wire.FilesystemKind, _: wire.IntentKind, _: bool, _: bool) !bool {
        return self.available;
    }
};

test "format and rename is one executable operation carrying the new filesystem label" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fixture();
    const parts = try a.dupe(wire.HostPartition, f.disk.partitions);
    parts[0].capabilities = &.{.{ .operation = .format, .backend = .host, .support = .available, .reason = "fixture" }};
    f.disk.partitions = parts;
    f.inventory.disks = &.{f.disk};
    for ([_]wire.FilesystemKind{ .ext4, .ntfs }) |fs| {
        var desired = @import("../../core/planning/editor.zig").retained(parts[0]);
        desired.name = "New label";
        desired.filesystem = fs;
        desired.retain_data = false;
        const draft = try @import("../../core/planning/editor.zig").generate(a, f.inventory, f.disk, &.{desired});
        try std.testing.expectEqual(@as(usize, 1), draft.intents.len);
        try std.testing.expectEqualStrings(desired.name, draft.intents[0].label.?);
        const result = try @import("../../core/planning/planner.zig").validate(a, f.inventory, draft, Capabilities{});
        try std.testing.expect(result.executable);
        try std.testing.expectEqual(@as(usize, 1), result.host_operations.len);
        try std.testing.expectEqual(.format, result.host_operations[0].kind);
        var missing_draft = draft;
        const intents = try a.dupe(wire.PlanIntent, draft.intents);
        intents[0].label = null;
        missing_draft.intents = intents;
        const missing = try @import("../../core/planning/planner.zig").validate(a, f.inventory, missing_draft, Capabilities{});
        try std.testing.expect(!missing.executable);
    }
}

test "offline admission rejects labels the maintenance compiler cannot honor" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fixture();
    f.inventory.disks = &.{f.disk};
    var desired = @import("../../core/planning/editor.zig").retained(f.disk.partitions[0]);
    desired.name = "Reviewed label";
    desired.retain_data = false;
    const draft = try @import("../../core/planning/editor.zig").generate(a, f.inventory, f.disk, &.{desired});
    const result = try @import("../../core/planning/planner.zig").validate(a, f.inventory, draft, Capabilities{ .available = false });
    for (result.diagnostics) |d| if (std.mem.eql(u8, d.code, "maintenance_label_unavailable") and d.severity == .@"error") return;
    return error.MissingMaintenanceLabelDiagnostic;
}
