//! Windows implementation of the application's disk boundary.
const Disk = @This();
const std = @import("std");
const proto = @import("proto");
const w = proto.wire;
const n = @import("native.zig");
const policy = @import("policy.zig");
const wmi = @import("wmi.zig");
io: std.Io,
failure: wmi.Failure = .{},
message_buffer: [2304]u8 = undefined,
pub fn query(self: *Disk, a: std.mem.Allocator) !w.InventorySnapshot {
    return @import("inventory.zig").query(a, self.io);
}
pub fn validLabel(_: *Disk, _: std.mem.Allocator, fs: w.FilesystemKind, label: []const u8) !bool {
    return policy.validLabel(fs, label);
}
pub fn canFs(_: *Disk, _: std.mem.Allocator, fs: w.FilesystemKind, op: w.IntentKind, _: bool, _: bool) !bool {
    return policy.canFs(fs, op);
}
pub fn preflightShrink(self: *Disk, a: std.mem.Allocator, part: w.HostPartition, length: u64) !void {
    self.failure = .{};
    checkShrink(a, part, length, &self.failure) catch |err| {
        if (self.failure.len == 0) {
            const name = @errorName(err);
            @memcpy(self.failure.detail[0..name.len], name);
            self.failure.len = name.len;
        }
        return error.HostPreflightFailed;
    };
}
pub fn apply(self: *Disk, a: std.mem.Allocator, disk: w.HostDisk, op: w.PlanIntent, desired: ?w.DesiredPartition) !void {
    self.failure = .{};
    const io = self.io;
    const failure = &self.failure;
    if (op.kind != .resize and op.kind != .label and op.kind != .format) return error.WindowsOperationUnsupported;
    // Do not trust a caller-supplied path or a previously generated capability.
    const fresh = try @import("inventory.zig").query(a, io);
    const current = try @import("../../execution/state.zig").disk(fresh, disk.identity orelse return error.MissingDiskIdentity);
    try @import("../../execution/state.zig").unchanged(disk, current);
    if (!std.mem.eql(u8, disk.path, current.path)) return error.DeviceIdentityChanged;
    const part = for (current.partitions) |p| {
        if (std.mem.eql(u8, p.id, op.partition_id)) break p;
    } else return error.MissingOperationTarget;
    if (part.protected or part.encryption != .none) return error.ProtectedWindowsVolume;
    const supported = for (part.capabilities) |cap| {
        if (cap.operation == op.kind and cap.backend == .host and cap.support == .available) break true;
    } else false;
    if (!supported) return error.WindowsOperationUnsupported;
    const target = desired orelse return error.MissingOperationTarget;
    const fs = (if (op.kind == .format) target.filesystem else part.filesystem) orelse return error.UnknownFilesystem;
    if (!policy.canFs(fs, op.kind)) return error.WindowsOperationUnsupported;
    if (op.kind != .resize and !policy.validLabel(fs, target.name)) return error.InvalidFilesystemLabel;
    if (!std.mem.eql(u8, target.offset, part.offset)) return error.WindowsMoveUnsupported;
    const apartment = try wmi.Apartment.init(failure);
    defer apartment.deinit();
    const connection = try wmi.Connection.init(a, wmi.STORAGE_NAMESPACE, failure);
    defer connection.deinit();
    const object = try find(a, connection, part);
    defer object.deinit();
    if (op.kind == .resize) {
        const size = try proto.byteCount(target.length);
        try bounds(a, connection, object, size);
        const result = try connection.method(a, object, "Resize", &.{.{ .name = n.wideLiteral("Size"), .value = .{ .uint64 = size } }});
        result.deinit();
        return;
    }
    const relpath = (try object.text(a, "__RELPATH")) orelse return error.WindowsObjectPathUnavailable;
    var volumes = try connection.query(a, try a.print("ASSOCIATORS OF {{{s}}} WHERE AssocClass = MSFT_PartitionToVolume", .{relpath}));
    defer volumes.deinit();
    const volume = (try volumes.next()) orelse return error.UnknownVolume;
    defer volume.deinit();
    const path = (try volume.text(a, "Path")) orelse return error.UnknownVolume;
    if (!std.ascii.eqlIgnoreCase(path, part.path orelse return error.UnknownVolume)) return error.VolumeMappingChanged;
    if (try volumes.next()) |extra| {
        extra.deinit();
        return error.VolumeMappingChanged;
    }
    const result = if (op.kind == .label)
        try connection.method(a, volume, "SetFileSystemLabel", &.{.{ .name = n.wideLiteral("FileSystemLabel"), .value = .{ .text = target.name } }})
    else
        try connection.method(a, volume, "Format", &.{
            .{ .name = n.wideLiteral("FileSystem"), .value = .{ .text = switch (fs) {
                .ntfs => "NTFS",
                .vfat => "FAT32",
                .exfat => "ExFAT",
                else => return error.UnknownFilesystem,
            } } },
            .{ .name = n.wideLiteral("FileSystemLabel"), .value = .{ .text = target.name } },
            .{ .name = n.wideLiteral("Full"), .value = .{ .boolean = false } },
            .{ .name = n.wideLiteral("Force"), .value = .{ .boolean = false } },
        });
    result.deinit();
}

pub fn failureMessage(self: *Disk, err: anyerror) []const u8 {
    return self.failure.message(&self.message_buffer, err);
}

fn find(a: std.mem.Allocator, connection: wmi.Connection, part: w.HostPartition) !wmi.Object {
    const uuid = try @import("../../planning/identity.zig").canonicalGuid(a, part.partition_uuid orelse return error.MissingPartitionIdentity);
    var objects = try connection.query(a, try a.print("SELECT * FROM MSFT_Partition WHERE Guid = '{s}'", .{uuid}));
    defer objects.deinit();
    const object = (try objects.next()) orelse return error.MissingOperationTarget;
    errdefer object.deinit();
    if (try objects.next()) |extra| {
        extra.deinit();
        return error.AmbiguousPartitionIdentity;
    }
    return object;
}
fn bounds(a: std.mem.Allocator, connection: wmi.Connection, part: wmi.Object, size: u64) !void {
    const result = try connection.method(a, part, "GetSupportedSize", &.{});
    defer result.deinit();
    if (size < try result.number("SizeMin") or size > try result.number("SizeMax")) return error.WindowsResizeOutsideSupportedRange;
}
fn checkShrink(a: std.mem.Allocator, part: w.HostPartition, size: u64, failure: *wmi.Failure) !void {
    const apartment = try wmi.Apartment.init(failure);
    defer apartment.deinit();
    const connection = try wmi.Connection.init(a, wmi.STORAGE_NAMESPACE, failure);
    defer connection.deinit();
    const object = try find(a, connection, part);
    defer object.deinit();
    try bounds(a, connection, object, size);
}
