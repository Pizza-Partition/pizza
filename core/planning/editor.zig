//! Stateless editing and draft generation. All clients use byte strings and GPT
//! identities; presentation, transport and platform discovery stay outside.
const std = @import("std");
const proto = @import("proto");
const w = proto.wire;
const identity = @import("identity.zig");
const Limits = @import("planner.zig").Limits;
const Allocator = std.mem.Allocator;
pub const Command = struct {
    kind: enum { resize, add_left, add_right, delete, format, label },
    partition_id: []const u8,
    length: ?[]const u8 = null,
    filesystem: ?w.FilesystemKind = null,
    name: ?[]const u8 = null,
};
pub const Request = struct {
    version: u16,
    snapshot_id: []const u8,
    disk_identity: []const u8,
    layout: ?[]const w.DesiredPartition = null,
    command: ?Command = null,
    review: bool = false,
    elevated: bool = false,
};
pub const Region = struct {
    id: []const u8,
    offset: []const u8,
    length: []const u8,
    name: []const u8,
    free: bool = false,
    filesystem: ?w.FilesystemKind = null,
    retain_data: bool = true,
    encryption: @FieldType(w.HostPartition, "encryption") = .none,
    protected: bool = false,
    capabilities: []const w.HostCapability = &.{},
    path: ?[]const u8 = null,
    used_bytes: ?[]const u8 = null,
    free_bytes: ?[]const u8 = null,
};
pub const Result = struct {
    version: u16 = proto.API_VERSION,
    draft: w.PlanDraft,
    regions: []const Region,
    selected: ?[]const u8 = null,
    validated: ?w.ValidatedPlan = null,
};
fn oldPartition(disk: w.HostDisk, id: []const u8) ?w.HostPartition {
    for (disk.partitions) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}
pub fn retained(p: w.HostPartition) w.DesiredPartition {
    return .{ .id = p.id, .offset = p.offset, .length = p.length, .name = p.name, .filesystem = p.filesystem, .slot = p.slot, .type_guid = p.type_guid, .partition_uuid = p.partition_uuid, .attributes = p.attributes orelse "0" };
}
/// Derive intents from the entire desired layout, never from a client-authored
/// operation list. Validation and approval still use the shared wire PlanDraft.
pub fn generate(a: Allocator, snapshot: w.InventorySnapshot, disk: w.HostDisk, layout: []const w.DesiredPartition) !w.PlanDraft {
    if (layout.len > Limits.PARTITIONS) return error.PlanTooLarge;
    var intents: std.ArrayList(w.PlanIntent) = .empty;
    for (disk.partitions) |old| {
        const p = for (layout) |p| {
            if (std.mem.eql(u8, p.id, old.id)) break p;
        } else {
            try intents.append(a, .{ .kind = .delete, .partition_id = old.id });
            continue;
        };
        if (!std.mem.eql(u8, p.offset, old.offset) or !std.mem.eql(u8, p.length, old.length)) try intents.append(a, .{ .kind = if (std.mem.eql(u8, p.length, old.length)) .move else .resize, .partition_id = p.id, .offset = p.offset, .length = p.length });
        if (!std.mem.eql(u8, p.name, old.name)) try intents.append(a, .{ .kind = .label, .partition_id = p.id, .label = p.name });
        if (!p.retain_data or p.filesystem != old.filesystem) try intents.append(a, .{ .kind = .format, .partition_id = p.id, .filesystem = p.filesystem });
    }
    for (layout) |p| if (oldPartition(disk, p.id) == null) try intents.append(a, .{ .kind = .create, .partition_id = p.id, .offset = p.offset, .length = p.length, .filesystem = p.filesystem, .label = p.name });
    return .{ .version = snapshot.version, .snapshot_id = snapshot.snapshot_id, .disk_identity = disk.identity orelse return error.DiskIdentityNotFound, .intents = intents.items, .layout = layout };
}
fn less(_: void, x: w.DesiredPartition, y: w.DesiredPartition) bool {
    return (proto.byteCount(x.offset) catch 0) < (proto.byteCount(y.offset) catch 0);
}
fn freeRegion(a: Allocator, offset: u64, length: u64) !Region {
    return .{ .id = try a.print("free:{d}", .{offset}), .offset = try a.print("{d}", .{offset}), .length = try a.print("{d}", .{length}), .name = "", .free = true };
}
pub fn regions(a: Allocator, disk: w.HostDisk, layout: []const w.DesiredPartition) ![]const Region {
    var out: std.ArrayList(Region) = .empty;
    var at = try proto.byteCount(disk.usable_offset orelse return error.UnknownUsableRange);
    const end = try std.math.add(u64, at, try proto.byteCount(disk.usable_length orelse return error.UnknownUsableRange));
    if (disk.sector_size < Limits.MINIMUM_SECTOR_BYTES or !std.math.isPowerOfTwo(disk.sector_size) or end > try proto.byteCount(disk.capacity)) return error.InvalidPartitionRange;
    for (layout, 0..) |p, i| {
        for (layout[0..i]) |other| if (std.mem.eql(u8, p.id, other.id)) return error.DuplicatePartition;
        const offset = try proto.byteCount(p.offset);
        const length = try proto.byteCount(p.length);
        const next = try std.math.add(u64, offset, length);
        if (offset < at or next > end or length == 0 or offset % disk.sector_size != 0 or length % disk.sector_size != 0) return error.InvalidPartitionRange;
        if (offset > at) try out.append(a, try freeRegion(a, at, offset - at));
        var r: Region = .{ .id = p.id, .offset = p.offset, .length = p.length, .name = p.name, .filesystem = p.filesystem, .retain_data = p.retain_data };
        if (oldPartition(disk, p.id)) |old| {
            r.encryption = old.encryption;
            r.protected = old.protected;
            r.capabilities = old.capabilities;
            r.path = old.path;
            r.used_bytes = old.used_bytes;
            r.free_bytes = old.free_bytes;
        } else r.capabilities = &.{
            .{ .operation = .resize, .support = .offline_check, .reason = "new_partition" },
            .{ .operation = .delete, .support = .offline_check, .reason = "new_partition" },
            .{ .operation = .format, .support = .offline_check, .reason = "new_partition" },
            .{ .operation = .label, .support = .offline_check, .reason = "new_partition" },
        };
        try out.append(a, r);
        at = next;
    }
    if (at < end) try out.append(a, try freeRegion(a, at, end - at));
    return out.items;
}
fn allowed(r: Region, kind: w.IntentKind) bool {
    if (r.free) return true;
    if (r.protected or r.encryption != .none) return false;
    for (r.capabilities) |c| if (c.operation == kind and c.support != .unavailable) return true;
    return false;
}
fn indexOf(layout: []const w.DesiredPartition, id: []const u8) !usize {
    for (layout, 0..) |p, i| if (std.mem.eql(u8, p.id, id)) return i;
    return error.PartitionNotFound;
}
fn geometry(a: Allocator, layout: []w.DesiredPartition, r: Region, offset: u64, length: u64) !void {
    if (r.free) return;
    const i = try indexOf(layout, r.id);
    layout[i].offset = try a.print("{d}", .{offset});
    layout[i].length = try a.print("{d}", .{length});
}
pub fn edit(a: Allocator, io: std.Io, snapshot: w.InventorySnapshot, request: Request) !Result {
    if (request.version != proto.API_VERSION or snapshot.version != proto.API_VERSION) return error.UnsupportedProtocolVersion;
    if (!std.mem.eql(u8, request.snapshot_id, snapshot.snapshot_id)) return error.StaleInventory;
    _ = try proto.hexDigest(request.disk_identity);
    const disk = for (snapshot.disks) |d| {
        if (d.identity) |id| if (std.mem.eql(u8, id, request.disk_identity)) break d;
    } else return error.DiskIdentityNotFound;
    if (disk.read_only or !std.mem.eql(u8, disk.partition_table orelse "", "gpt")) return error.DiskNotEditable;
    var layout: std.ArrayList(w.DesiredPartition) = .empty;
    if (request.layout) |items| {
        if (items.len > Limits.PARTITIONS) return error.PlanTooLarge;
        try layout.appendSlice(a, items);
    } else for (disk.partitions) |p| try layout.append(a, retained(p));
    std.mem.sort(w.DesiredPartition, layout.items, {}, less);
    const spans = try regions(a, disk, layout.items);
    var selected: ?[]const u8 = null;
    if (request.command) |cmd| {
        const ri = for (spans, 0..) |r, i| {
            if (std.mem.eql(u8, r.id, cmd.partition_id)) break i;
        } else return error.PartitionNotFound;
        const r = spans[ri];
        const kind: w.IntentKind = switch (cmd.kind) {
            .resize, .add_left, .add_right => .resize,
            .delete => .delete,
            .format => .format,
            .label => .label,
        };
        if (!allowed(r, kind)) return error.OperationUnavailable;
        const offset = try proto.byteCount(r.offset);
        const length = try proto.byteCount(r.length);
        const sector: u64 = disk.sector_size;
        selected = r.id;
        switch (cmd.kind) {
            .resize => {
                if (ri + 1 == spans.len) return error.NoAdjacentRegion;
                const right = spans[ri + 1];
                if (!allowed(right, .resize)) return error.OperationUnavailable;
                const total = try std.math.add(u64, length, try proto.byteCount(right.length));
                const n = (try proto.byteCount(cmd.length orelse return error.MissingLength)) / sector * sector;
                if (n > total or n < (if (r.free) @as(u64, 0) else sector) or total - n < (if (right.free) @as(u64, 0) else sector)) return error.InvalidPartitionRange;
                try geometry(a, layout.items, r, offset, n);
                try geometry(a, layout.items, right, offset + n, total - n);
            },
            .delete => {
                if (r.free) return error.PartitionNotFound;
                _ = layout.orderedRemove(try indexOf(layout.items, r.id));
                selected = null;
            },
            .format, .label => {
                if (r.free) return error.PartitionNotFound;
                const p = &layout.items[try indexOf(layout.items, r.id)];
                if (cmd.kind == .format) {
                    p.filesystem = cmd.filesystem orelse return error.MissingFilesystem;
                    p.retain_data = false;
                    if (oldPartition(disk, p.id) == null) p.type_guid = identity.Gpt.filesystemType(p.filesystem.?);
                } else p.name = cmd.name orelse return error.MissingLabel;
            },
            .add_left, .add_right => {
                const half = length / 2 / sector * sector;
                if (half < sector) return error.InsufficientFreeSpace;
                const left = cmd.kind == .add_left;
                const new_length = if (r.free or left) half else length - half;
                const new_offset = if (left) offset else offset + length - new_length;
                if (!r.free) try geometry(a, layout.items, r, if (left) offset + half else offset, if (left) length - half else half);
                var uuid: [16]u8 = undefined;
                io.random(&uuid);
                uuid[7] = (uuid[7] & 15) | 64;
                uuid[8] = (uuid[8] & 63) | 128;
                const text = try a.dupe(u8, &std.fmt.bytesToHex(uuid, .lower));
                const id = try identity.partition(a, request.disk_identity, text);
                const fs = cmd.filesystem orelse return error.MissingFilesystem;
                try layout.append(a, .{ .id = id, .offset = try a.print("{d}", .{new_offset}), .length = try a.print("{d}", .{new_length}), .name = cmd.name orelse "", .filesystem = fs, .retain_data = false, .partition_uuid = text, .type_guid = identity.Gpt.filesystemType(fs) });
                selected = id;
            },
        }
    }
    std.mem.sort(w.DesiredPartition, layout.items, {}, less);
    return .{ .draft = try generate(a, snapshot, disk, layout.items), .regions = try regions(a, disk, layout.items), .selected = selected };
}

const TestCapabilities = struct {
    pub fn validLabel(_: @This(), _: Allocator, _: w.FilesystemKind, _: []const u8) !bool {
        return true;
    }
    pub fn canFs(_: @This(), _: Allocator, _: w.FilesystemKind, _: w.IntentKind, _: bool, _: bool) !bool {
        return true;
    }
};
fn fixture() w.InventorySnapshot {
    return .{ .version = proto.API_VERSION, .snapshot_id = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .platform = .windows, .disks = &.{.{
        .identity = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .path = "test-only",
        .model = "fixture",
        .capacity = "10485760",
        .sector_size = 4096,
        .partition_table = "gpt",
        .read_only = false,
        .usable_offset = "1048576",
        .usable_length = "8388608",
        .partitions = &.{.{ .id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .offset = "1048576", .length = "4194304", .name = "", .filesystem = .ntfs, .encryption = .none, .capabilities = &.{
            .{ .operation = .resize, .support = .available, .backend = .host, .reason = "fixture", .grow = true, .shrink = true },
            .{ .operation = .format, .support = .available, .backend = .host, .reason = "fixture" },
            .{ .operation = .delete, .support = .available, .backend = .host, .reason = "fixture" },
            .{ .operation = .label, .support = .available, .backend = .host, .reason = "fixture" },
        } }},
    }} };
}
fn editRequest(s: w.InventorySnapshot, layout: ?[]const w.DesiredPartition, command: ?Command) Request {
    return .{ .version = s.version, .snapshot_id = s.snapshot_id, .disk_identity = s.disks[0].identity.?, .layout = layout, .command = command };
}
test "backend edits resize, format, label, create and delete without UI or system imports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = fixture();
    const initial = try edit(a, std.testing.io, s, editRequest(s, null, null));
    try std.testing.expectEqual(0, initial.draft.intents.len);
    try std.testing.expectEqual(2, initial.regions.len);
    try std.testing.expectEqualStrings("", initial.regions[1].name);
    const id = initial.draft.layout[0].id;
    const resized = try edit(a, std.testing.io, s, editRequest(s, initial.draft.layout, .{ .kind = .resize, .partition_id = id, .length = "3149825" }));
    try std.testing.expectEqualStrings("3149824", resized.draft.layout[0].length);
    try std.testing.expectEqual(.resize, resized.draft.intents[0].kind);
    const formatted = try edit(a, std.testing.io, s, editRequest(s, resized.draft.layout, .{ .kind = .format, .partition_id = id, .filesystem = .exfat }));
    try std.testing.expect(!formatted.draft.layout[0].retain_data);
    try std.testing.expectEqual(.format, formatted.draft.intents[1].kind);
    var random_label: [8]u8 = undefined;
    std.testing.io.random(&random_label);
    const requested_label = try a.dupe(u8, &std.fmt.bytesToHex(random_label, .lower));
    const labeled = try edit(a, std.testing.io, s, editRequest(s, formatted.draft.layout, .{ .kind = .label, .partition_id = id, .name = requested_label }));
    try std.testing.expectEqualStrings(requested_label, labeled.draft.layout[0].name);
    try std.testing.expectEqual(.label, labeled.draft.intents[1].kind);
    const cleared = try edit(a, std.testing.io, s, editRequest(s, labeled.draft.layout, .{ .kind = .label, .partition_id = id, .name = "" }));
    try std.testing.expectEqualStrings("", cleared.draft.layout[0].name);
    try std.testing.expectEqual(2, cleared.draft.intents.len);
    const created = try edit(a, std.testing.io, s, editRequest(s, labeled.draft.layout, .{ .kind = .add_right, .partition_id = labeled.regions[1].id, .filesystem = .ntfs }));
    const added = created.draft.layout[1];
    try std.testing.expectEqualStrings("", added.name);
    try std.testing.expectEqualStrings(added.id, try identity.partition(a, s.disks[0].identity.?, added.partition_uuid.?));
    try std.testing.expectEqualStrings("a2a0d0ebe5b9334487c068b6b72699c7", added.type_guid.?);
    try std.testing.expectEqual(.create, created.draft.intents[3].kind);
    const removed = try edit(a, std.testing.io, s, editRequest(s, created.draft.layout, .{ .kind = .delete, .partition_id = added.id }));
    try std.testing.expectEqual(1, removed.draft.layout.len);
    try std.testing.expectEqual(3, removed.draft.intents.len);
    const empty = try edit(a, std.testing.io, s, editRequest(s, removed.draft.layout, .{ .kind = .delete, .partition_id = id }));
    try std.testing.expectEqual(.delete, empty.draft.intents[0].kind);
    try std.testing.expectEqual(1, empty.regions.len);
    try std.testing.expectEqualStrings("8388608", empty.regions[0].length);
}
test "backend splits either side with exact coverage and unique GPT identities" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = fixture();
    var previous: ?[]const u8 = null;
    for ([_]Command{ .{ .kind = .add_left, .partition_id = s.disks[0].partitions[0].id, .filesystem = .ntfs }, .{ .kind = .add_right, .partition_id = s.disks[0].partitions[0].id, .filesystem = .ntfs } }) |command| {
        const result = try edit(a, std.testing.io, s, editRequest(s, null, command));
        try std.testing.expectEqual(2, result.draft.layout.len);
        try std.testing.expectEqualStrings("2097152", result.draft.layout[0].length);
        try std.testing.expectEqualStrings("3145728", result.draft.layout[1].offset);
        const id = result.selected.?;
        if (previous) |p| try std.testing.expect(!std.mem.eql(u8, p, id));
        previous = id;
        const plan = try @import("planner.zig").validate(a, s, result.draft, TestCapabilities{});
        for (plan.diagnostics) |d| try std.testing.expect(d.severity != .@"error");
        try std.testing.expectEqual(command.kind == .add_left, plan.offline_validation_required);
    }
}
test "backend rejects stale inventory, forged geometry, oversized layouts and unsupported boundaries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = fixture();
    var request = editRequest(s, null, null);
    request.snapshot_id = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    try std.testing.expectError(error.StaleInventory, edit(a, std.testing.io, s, request));
    request = editRequest(s, null, .{ .kind = .resize, .partition_id = s.disks[0].partitions[0].id, .length = "0" });
    try std.testing.expectError(error.InvalidPartitionRange, edit(a, std.testing.io, s, request));
    var bad = retained(s.disks[0].partitions[0]);
    bad.offset = "18446744073709547520";
    try std.testing.expectError(error.Overflow, edit(a, std.testing.io, s, editRequest(s, &.{bad}, null)));
    bad = retained(s.disks[0].partitions[0]);
    try std.testing.expectError(error.DuplicatePartition, edit(a, std.testing.io, s, editRequest(s, &.{ bad, bad }, null)));
    const huge = try a.alloc(w.DesiredPartition, Limits.PARTITIONS + 1);
    try std.testing.expectError(error.PlanTooLarge, edit(a, std.testing.io, s, editRequest(s, huge, null)));
    var parts = try a.dupe(w.HostPartition, s.disks[0].partitions);
    var disks = try a.dupe(w.HostDisk, s.disks);
    disks[0].partitions = parts;
    var locked = s;
    locked.disks = disks;
    for ([_]bool{ false, true }) |protected| {
        parts[0].encryption = if (protected) .none else .encrypted;
        parts[0].protected = protected;
        inline for ([_]Command{ .{ .kind = .delete, .partition_id = bad.id }, .{ .kind = .add_left, .partition_id = bad.id, .filesystem = .ntfs }, .{ .kind = .label, .partition_id = bad.id, .name = "blocked" } }) |command|
            try std.testing.expectError(error.OperationUnavailable, edit(a, std.testing.io, locked, editRequest(locked, null, command)));
    }
}
test "backend keeps uint64 geometry exact above JavaScript Number range" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = fixture();
    var disks = try a.dupe(w.HostDisk, s.disks);
    disks[0].capacity = "18446744073709547520";
    disks[0].usable_length = "18446744073707450368";
    disks[0].partitions = &.{};
    s.disks = disks;
    const result = try edit(a, std.testing.io, s, editRequest(s, null, .{ .kind = .add_right, .partition_id = "free:1048576", .filesystem = .ntfs }));
    const p = result.draft.layout[0];
    try std.testing.expectEqualStrings("9223372036854775808", p.offset);
    try std.testing.expectEqualStrings("9223372036853723136", p.length);
}

test "editing is independent of fixture size, filesystem and logical sector geometry" {
    for ([_]u32{ 512, 4096, 8192 }) |sector| for (std.meta.tags(w.FilesystemKind)) |fs| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var snapshot = fixture();
        var disks = try a.dupe(w.HostDisk, snapshot.disks);
        const start: u64 = @as(u64, sector) * 257;
        const usable: u64 = @as(u64, sector) * 4099;
        disks[0].sector_size = sector;
        disks[0].capacity = try a.print("{d}", .{start + usable + sector});
        disks[0].usable_offset = try a.print("{d}", .{start});
        disks[0].usable_length = try a.print("{d}", .{usable});
        disks[0].partitions = &.{};
        snapshot.disks = disks;
        const opened = try edit(a, std.testing.io, snapshot, editRequest(snapshot, null, null));
        const created = try edit(a, std.testing.io, snapshot, editRequest(snapshot, null, .{ .kind = .add_left, .partition_id = opened.regions[0].id, .filesystem = fs, .name = "matrix" }));
        const p = created.draft.layout[0];
        try std.testing.expectEqual(fs, p.filesystem.?);
        try std.testing.expectEqual(start, try proto.byteCount(p.offset));
        try std.testing.expectEqual(usable / 2 / sector * sector, try proto.byteCount(p.length));
        try std.testing.expectEqualStrings(p.id, try identity.partition(a, disks[0].identity.?, p.partition_uuid.?));
        const changed = try edit(a, std.testing.io, snapshot, editRequest(snapshot, created.draft.layout, .{ .kind = .resize, .partition_id = p.id, .length = try a.print("{d}", .{usable - sector}) }));
        try std.testing.expectEqual(@as(u64, sector), try proto.byteCount(changed.regions[1].length));
        const removed = try edit(a, std.testing.io, snapshot, editRequest(snapshot, changed.draft.layout, .{ .kind = .delete, .partition_id = p.id }));
        try std.testing.expectEqual(0, removed.draft.intents.len);
        try std.testing.expectEqual(usable, try proto.byteCount(removed.regions[0].length));
    };
}
