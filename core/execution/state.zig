//! Postconditions prevent a successful library return from hiding a different layout.
const std = @import("std");
const wire = @import("proto").wire;
fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |value| return b != null and std.mem.eql(u8, value, b.?);
    return b == null;
}
pub fn disk(snapshot: wire.InventorySnapshot, identity: []const u8) !wire.HostDisk {
    for (snapshot.disks) |d| if (d.identity) |id| if (std.mem.eql(u8, id, identity)) return d;
    return error.DeviceIdentityChanged;
}
fn find(parts: []const wire.HostPartition, id: []const u8) ?wire.HostPartition {
    for (parts) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}
pub fn unchanged(before: wire.HostDisk, after: wire.HostDisk) !void {
    if (!std.mem.eql(u8, before.identity orelse "", after.identity orelse "") or
        !std.mem.eql(u8, before.capacity, after.capacity) or before.sector_size != after.sector_size or
        before.read_only != after.read_only or before.partitions.len != after.partitions.len or
        !optionalEqual(before.partition_table, after.partition_table) or
        !optionalEqual(before.usable_offset, after.usable_offset) or
        !optionalEqual(before.usable_length, after.usable_length))
        return error.LayoutChanged;
    for (before.partitions) |p| {
        const q = find(after.partitions, p.id) orelse return error.LayoutChanged;
        if (!std.mem.eql(u8, p.offset, q.offset) or !std.mem.eql(u8, p.length, q.length) or
            !std.mem.eql(u8, p.name, q.name) or p.filesystem != q.filesystem or
            p.encryption != q.encryption or p.protected != q.protected or
            !std.mem.eql(u8, p.attributes orelse "0", q.attributes orelse "0") or
            !optionalEqual(p.type_guid, q.type_guid) or
            !optionalEqual(p.partition_uuid, q.partition_uuid) or p.slot != q.slot) return error.LayoutChanged;
        if (p.mountpoints.len != q.mountpoints.len) return error.OccupancyChanged;
        for (p.mountpoints, q.mountpoints) |pm, qm| if (!std.mem.eql(u8, pm, qm)) return error.OccupancyChanged;
    }
}
pub fn verify(before: wire.HostDisk, after: wire.HostDisk, op: wire.PlanIntent, desired: ?wire.DesiredPartition) !void {
    if (!std.mem.eql(u8, before.identity orelse "", after.identity orelse "") or
        !std.mem.eql(u8, before.capacity, after.capacity) or before.sector_size != after.sector_size or after.read_only or
        !optionalEqual(before.partition_table, after.partition_table) or
        !optionalEqual(before.usable_offset, after.usable_offset) or
        !optionalEqual(before.usable_length, after.usable_length))
        return error.DeviceIdentityChanged;
    const old = find(before.partitions, op.partition_id);
    if (op.kind != .create and old == null) return error.MissingOperationTarget;
    const count = switch (op.kind) {
        .create => before.partitions.len + 1,
        .delete => before.partitions.len - 1,
        else => before.partitions.len,
    };
    if (after.partitions.len != count) return error.OperationPostconditionFailed;
    for (before.partitions) |p| {
        if (std.mem.eql(u8, p.id, op.partition_id)) continue;
        const q = find(after.partitions, p.id) orelse return error.UnexpectedPartitionChange;
        try unchanged(.{ .path = before.path, .identity = before.identity, .capacity = before.capacity, .sector_size = before.sector_size, .model = before.model, .read_only = before.read_only, .partitions = &.{p} }, .{ .path = after.path, .identity = after.identity, .capacity = after.capacity, .sector_size = after.sector_size, .model = after.model, .read_only = after.read_only, .partitions = &.{q} });
    }
    if (op.kind == .delete) {
        if (find(after.partitions, op.partition_id) != null) return error.OperationPostconditionFailed;
        return;
    }
    const target = find(after.partitions, op.partition_id) orelse return error.OperationPostconditionFailed;
    const p = desired orelse return error.MissingOperationTarget;
    const preserves_geometry = op.kind == .label or op.kind == .format;
    const fs = if (op.kind == .resize or op.kind == .label) old.?.filesystem else p.filesystem;
    if (!std.mem.eql(u8, target.offset, if (preserves_geometry) old.?.offset else p.offset) or
        !std.mem.eql(u8, target.length, if (preserves_geometry) old.?.length else p.length) or target.filesystem != fs)
        return error.OperationPostconditionFailed;
    if (old) |prior| {
        if (!optionalEqual(target.type_guid, prior.type_guid) or
            !optionalEqual(target.partition_uuid, prior.partition_uuid) or target.slot != prior.slot or
            !std.mem.eql(u8, target.attributes orelse "0", prior.attributes orelse "0")) return error.UnexpectedPartitionChange;
    }
    // Resize retains the current label; a separate label step may follow it.
    const name = if (op.kind == .resize) old.?.name else p.name;
    if (!std.mem.eql(u8, target.name, name)) return error.OperationPostconditionFailed;
}

test "library success is insufficient when the resulting geometry differs" {
    const p: wire.HostPartition = .{ .id = "p", .offset = "1048576", .length = "4194304", .name = "", .encryption = .none, .filesystem = .ext4 };
    const before: wire.HostDisk = .{ .path = "/dev/fixture", .identity = "disk", .capacity = "16777216", .sector_size = 512, .model = "fixture", .read_only = false, .partitions = &.{p} };
    var after = before;
    const target: wire.DesiredPartition = .{ .id = "p", .offset = p.offset, .length = "2097152", .name = p.name, .filesystem = p.filesystem };
    const op: wire.PlanIntent = .{ .kind = .resize, .partition_id = p.id, .length = target.length };
    try std.testing.expectError(error.OperationPostconditionFailed, verify(before, after, op, target));
    var smaller = p;
    smaller.length = target.length;
    after.partitions = &.{smaller};
    try verify(before, after, op, target);
    try std.testing.expectError(error.LayoutChanged, unchanged(before, after));
}

test "unexpected disappearance of an unrelated partition fails verification" {
    const p: wire.HostPartition = .{ .id = "p", .offset = "1048576", .length = "4194304", .name = "", .encryption = .none, .filesystem = .ext4 };
    var other = p;
    other.id = "other";
    other.offset = "6291456";
    const before: wire.HostDisk = .{ .path = "/dev/fixture", .identity = "disk", .capacity = "16777216", .sector_size = 512, .model = "fixture", .read_only = false, .partitions = &.{ p, other } };
    var after = before;
    after.partitions = &.{p};
    try std.testing.expectError(error.UnexpectedPartitionChange, verify(before, after, .{ .kind = .delete, .partition_id = "p" }, null));
}

test "format and label verify their own step rather than a later target geometry" {
    const p: wire.HostPartition = .{ .id = "p", .offset = "1048576", .length = "4194304", .name = "Before", .encryption = .none, .filesystem = .ext4 };
    const before: wire.HostDisk = .{ .path = "/dev/fixture", .identity = "disk", .capacity = "16777216", .sector_size = 512, .model = "fixture", .read_only = false, .partitions = &.{p} };
    const desired: wire.DesiredPartition = .{ .id = "p", .offset = p.offset, .length = "8388608", .name = "After", .filesystem = .ntfs };
    var renamed = p;
    renamed.name = desired.name;
    var after = before;
    after.partitions = &.{renamed};
    try verify(before, after, .{ .kind = .label, .partition_id = "p" }, desired);
    var formatted = renamed;
    formatted.filesystem = .ntfs;
    after.partitions = &.{formatted};
    try verify(before, after, .{ .kind = .format, .partition_id = "p" }, desired);
    formatted.type_guid = "changed";
    after.partitions = &.{formatted};
    try std.testing.expectError(error.UnexpectedPartitionChange, verify(before, after, .{ .kind = .format, .partition_id = "p" }, desired));
    try std.testing.expectError(error.MissingOperationTarget, verify(before, after, .{ .kind = .delete, .partition_id = "missing" }, null));
}
