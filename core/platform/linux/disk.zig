//! Linux disk discovery and filesystem capabilities used by the application.
const Disk = @This();
const std = @import("std");
const wire = @import("proto").wire;
const blockdev = @import("blockdev.zig");
io: std.Io,

pub fn query(self: *Disk, a: std.mem.Allocator) !wire.InventorySnapshot {
    return @import("inventory.zig").query(a, self.io);
}
pub fn validLabel(_: *Disk, a: std.mem.Allocator, fs: wire.FilesystemKind, label: []const u8) !bool {
    return blockdev.validLabel(@tagName(fs), try a.dupeSentinel(u8, label, 0));
}
pub fn canFs(_: *Disk, _: std.mem.Allocator, fs: wire.FilesystemKind, op: wire.IntentKind, mounted: bool, shrinking: bool) !bool {
    return blockdev.canFs(@tagName(fs), op, mounted, shrinking);
}
pub fn preflightShrink(_: *Disk, a: std.mem.Allocator, part: wire.HostPartition, length: u64) !void {
    try blockdev.preflightShrink(try a.dupeSentinel(u8, part.path orelse return error.UnknownPartitionPath, 0), @tagName(part.filesystem orelse return error.UnknownFilesystem), length, part.mountpoints.len != 0);
}
pub fn apply(self: *Disk, a: std.mem.Allocator, disk: wire.HostDisk, intent: wire.PlanIntent, desired: ?wire.DesiredPartition) !void {
    const old: ?wire.HostPartition = for (disk.partitions) |p| {
        if (std.mem.eql(u8, p.id, intent.partition_id)) break p;
    } else null;
    if (old) |p| {
        if (try @import("inventory.zig").inUse(a, self.io, p.path orelse return error.UnknownPartitionPath)) return error.DeviceBusy;
        if (p.protected or disk.read_only or (p.encryption != .none and intent.kind != .delete)) return error.OperationUnavailable;
    }
    const fs = if (intent.kind == .resize) (if (old) |p| p.filesystem else null) else if (desired) |p| p.filesystem else if (old) |p| p.filesystem else null;
    return blockdev.perform(.{
        .disk = try a.dupeSentinel(u8, disk.path, 0),
        .part = try a.dupeSentinel(u8, if (old) |v| v.path orelse return error.UnknownPartitionPath else "", 0),
        .kind = intent.kind,
        .filesystem = try a.dupeSentinel(u8, if (fs) |v| @tagName(v) else "", 0),
        .label = try a.dupeSentinel(u8, if (desired) |v| v.name else "", 0),
        .uuid = try a.dupeSentinel(u8, if (desired) |v| v.partition_uuid orelse "" else "", 0),
        .type_guid = try a.dupeSentinel(u8, if (desired) |v| v.type_guid orelse "" else "", 0),
        .offset = if (desired) |v| try @import("proto").byteCount(v.offset) else 0,
        .length = if (desired) |v| try @import("proto").byteCount(v.length) else 0,
        .mounted = if (old) |v| v.mountpoints.len != 0 else false,
    });
}

pub fn failureMessage(_: *Disk, err: anyerror) []const u8 {
    const detail = blockdev.lastError();
    return if (detail.len == 0) @errorName(err) else detail;
}
