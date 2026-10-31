//! Staging on an explicitly identified FAT32 ESP. No drive-letter assignment,
//! mountvol, BCD commands, arbitrary paths or raw writes to a Windows disk.
const std = @import("std");
const proto = @import("proto");
const n = @import("native.zig");
const boot = @import("../../boot/session.zig");
const staging = @import("../../boot/staging.zig");
const filename = staging.filename;
const limit = staging.limit;
const identity = @import("../../planning/identity.zig");
const ESP_TYPE = &identity.Gpt.ESP;
pub const Esp = struct {
    a: std.mem.Allocator,
    disk_path: []const u8,
    disk_identity: boot.Digest,
    session_id: boot.Digest,
    disk_number: u32,
    partition_uuid: [16]u8,
    offset: u64,
    length: u64,
    volume: []const u8,
    directory: []const u8,
    relative: []const u8,
    directories: [11]?n.f.HANDLE = @splat(null),

    /// Discovery and creation are separate from boot arming. Call reserve() for
    /// EVERY file before the offline compiler captures its FAT allocation proof.
    pub fn open(a: std.mem.Allocator, io: std.Io, disk: proto.wire.HostDisk, part: proto.wire.HostPartition, session: []const u8, create: bool) !Esp {
        if (!@import("session/security.zig").elevated()) return error.AdministratorRequired;
        if (!@import("../../execution/worker.zig").validId(session)) return error.InvalidSession;
        if (disk.read_only or !std.mem.eql(u8, disk.partition_table orelse "", "gpt") or
            !std.mem.eql(u8, part.type_guid orelse "", ESP_TYPE)) return error.EspRequired;
        const handle = try n.open(a, disk.path, n.GENERIC_READ);
        defer n.close(handle);
        const number = try n.deviceNumber(handle);
        const uuid = try identity.guid(part.partition_uuid orelse return error.MissingPartitionIdentity);
        const id = try proto.hexDigest(disk.identity orelse return error.MissingDiskIdentity);
        const native_id = try n.maintenanceIdentity(a, handle) orelse return error.NonPortableDeviceIdentity;
        if (!std.mem.eql(u8, &native_id, &id)) return error.DeviceIdentityChanged;
        const offset = try proto.byteCount(part.offset);
        const length = try proto.byteCount(part.length);
        const volume = try findVolume(a, number, offset, length);
        var fs: [32:0]u16 = @splat(0);
        if (n.k.GetVolumeInformationW(try n.wide(a, volume), null, 0, null, null, null, &fs, fs.len) == 0 or
            !std.mem.eql(u16, std.mem.sliceTo(&fs, 0), n.wideLiteral("FAT32"))) return error.Fat32EspRequired;
        var self: Esp = .{ .a = a, .disk_path = disk.path, .disk_identity = id, .session_id = try proto.hexDigest(session), .disk_number = number, .partition_uuid = uuid, .offset = offset, .length = length, .volume = volume, .directory = volume, .relative = "", .directories = @splat(null) };
        errdefer self.close(io);
        try self.verifyMapping();
        self.directories[0] = try directory(a, volume);
        var current_path = std.mem.trimEnd(u8, volume, "\\");
        var relative: std.ArrayList(u8) = .empty;
        for (try staging.segments(a, session), 0..) |segment, index| {
            current_path = try a.print("{s}\\{s}", .{ current_path, segment });
            try relative.append(a, '\\');
            try relative.appendSlice(a, segment);
            if (create and n.k.CreateDirectoryW(try n.wide(a, current_path), null) == 0 and n.k.GetLastError() != .ERROR_ALREADY_EXISTS) return error.EspDirectoryUnavailable;
            self.directories[index + 1] = try directory(a, current_path);
        }
        self.directory = current_path;
        self.relative = try relative.toOwnedSlice(a);
        return self;
    }
    pub fn close(self: *Esp, _: std.Io) void {
        for (&self.directories) |*handle| {
            if (handle.*) |h| n.close(h);
            handle.* = null;
        }
    }
    pub fn imagePath(self: Esp) ![]const u8 {
        return self.a.print("{s}\\maint.efi", .{self.relative});
    }
    pub const bootPath = staging.bootPath;
    pub fn store(self: *Esp) boot.Store {
        return .{ .context = self, .read = read, .publish = publish };
    }
    /// Caller must first persist the terminal report and remove the firmware
    /// pin. Keep the small request/receipt as evidence; release large staging.
    pub fn releaseReservations(self: *Esp) !void {
        try self.verifyMapping();
        for ([_]boot.File{ .image, .manifest, .anchor }) |file| {
            const target = try self.path(file);
            defer self.a.free(target);
            const h = n.valid(n.k.CreateFileW(target, @bitCast(n.GENERIC_READ | 0x00010000), .{}, null, .OPEN_EXISTING, .{ .FILE_FLAG_OPEN_REPARSE_POINT = 1 }, null)) orelse {
                if (n.k.GetLastError() == .ERROR_FILE_NOT_FOUND) continue;
                return error.EspCleanupFailed;
            };
            defer n.close(h);
            try regular(h);
            var disposition: n.fs.FILE_DISPOSITION_INFO = .{ .DeleteFile = 1 };
            if (n.k.SetFileInformationByHandle(h, .FileDispositionInfo, &disposition, @sizeOf(@TypeOf(disposition))) == 0) return error.EspCleanupFailed;
        }
        const volume = try n.open(self.a, std.mem.trimEnd(u8, self.volume, "\\"), n.GENERIC_WRITE);
        defer n.close(volume);
        if (n.k.FlushFileBuffers(volume) == 0) return error.EspSyncFailed;
    }
    fn verifyMapping(self: *Esp) !void {
        var arena: std.heap.ArenaAllocator = .init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        const disk = try n.open(a, self.disk_path, n.GENERIC_READ);
        defer n.close(disk);
        if (try n.deviceNumber(disk) != self.disk_number) return error.DeviceIdentityChanged;
        const id = try n.maintenanceIdentity(a, disk) orelse return error.NonPortableDeviceIdentity;
        if (!std.mem.eql(u8, &id, &self.disk_identity)) return error.DeviceIdentityChanged;
        const layout = try n.readLayout(a, disk);
        defer layout.deinit(a);
        var matches: usize = 0;
        for (layout.entries) |part| {
            if (part.PartitionStyle != .GPT or !std.mem.eql(u8, std.mem.asBytes(&part.Anonymous.Gpt.PartitionId), &self.partition_uuid)) continue;
            if (part.StartingOffset.QuadPart < 0 or part.PartitionLength.QuadPart <= 0 or
                @as(u64, @intCast(part.StartingOffset.QuadPart)) != self.offset or
                @as(u64, @intCast(part.PartitionLength.QuadPart)) != self.length or
                !std.mem.eql(u8, std.mem.asBytes(&part.Anonymous.Gpt.PartitionType), &try identity.guid(ESP_TYPE))) return error.EspPartitionChanged;
            matches += 1;
        }
        if (matches != 1 or !n.simpleVolume(a, self.volume, self.disk_number, self.offset, self.length)) return error.EspMappingChanged;
    }
    fn path(self: *Esp, file: boot.File) ![:0]const u16 {
        const text = try self.a.print("{s}\\{s}", .{ self.directory, filename(file) });
        defer self.a.free(text);
        return n.wide(self.a, text);
    }
    /// Write every byte; setting a sparse EOF is not a capacity reservation.
    /// Existing files are never truncated or reused by this operation.
    pub fn reserve(self: *Esp, file: boot.File, bytes: u64) !void {
        if (bytes == 0 or bytes > limit(file)) return error.InvalidStageReservation;
        try self.verifyMapping();
        const target = try self.path(file);
        defer self.a.free(target);
        const h = n.valid(n.k.CreateFileW(target, @bitCast(n.GENERIC_READ | n.GENERIC_WRITE), .{}, null, .CREATE_NEW, .{ .FILE_FLAG_WRITE_THROUGH = 1, .FILE_FLAG_OPEN_REPARSE_POINT = 1 }, null)) orelse return error.StageReservationFailed;
        defer n.close(h);
        var left = bytes;
        const zero: [65536]u8 = @splat(0);
        while (left != 0) {
            const size: usize = @intCast(@min(left, zero.len));
            try writeAll(h, zero[0..size]);
            left -= size;
        }
        try self.flush(h);
        if (try fileSize(h) != bytes) return error.StageReservationFailed;
    }
    /// Preparation retries may reuse a reservation of exactly the same size.
    /// The controller forbids this operation after installing a firmware pin.
    pub fn ensureReserved(self: *Esp, file: boot.File, bytes: u64) !void {
        if (bytes == 0 or bytes > limit(file)) return error.InvalidStageReservation;
        try self.verifyMapping();
        const target = try self.path(file);
        defer self.a.free(target);
        const h = n.valid(n.k.CreateFileW(target, @bitCast(n.GENERIC_READ), .{}, null, .OPEN_EXISTING, .{ .FILE_FLAG_OPEN_REPARSE_POINT = 1 }, null)) orelse {
            if (n.k.GetLastError() == .ERROR_FILE_NOT_FOUND) return self.reserve(file, bytes);
            return error.StageReservationFailed;
        };
        defer n.close(h);
        try regular(h);
        if (try fileSize(h) != bytes) return error.StageReservationSizeChanged;
    }
    fn flush(self: *Esp, file: n.f.HANDLE) !void {
        if (n.k.FlushFileBuffers(file) == 0) return error.EspSyncFailed;
        // Directory handles cannot reliably be flushed on Windows. Flush the
        // admitted FAT volume so allocation and directory entries persist too.
        const volume = try n.open(self.a, std.mem.trimEnd(u8, self.volume, "\\"), n.GENERIC_WRITE);
        defer n.close(volume);
        if (n.k.FlushFileBuffers(volume) == 0) return error.EspSyncFailed;
    }
    fn publish(ctx: *anyopaque, _: std.Io, file: boot.File, bytes: []const u8) !void {
        const self: *Esp = @ptrCast(@alignCast(ctx));
        if (bytes.len == 0 or bytes.len > limit(file)) return error.StagedArtifactTooLarge;
        try self.verifyMapping();
        const target = try self.path(file);
        defer self.a.free(target);
        const h = n.valid(n.k.CreateFileW(target, @bitCast(n.GENERIC_READ | n.GENERIC_WRITE), .{}, null, .OPEN_EXISTING, .{ .FILE_FLAG_WRITE_THROUGH = 1, .FILE_FLAG_OPEN_REPARSE_POINT = 1 }, null)) orelse return error.StageNotReserved;
        defer n.close(h);
        try regular(h);
        // Reallocation or rename would invalidate the authenticated FAT proof.
        if (try fileSize(h) != bytes.len) return error.StageReservationSizeChanged;
        try writeAll(h, bytes);
        try self.flush(h);
    }
    fn read(ctx: *anyopaque, a: std.mem.Allocator, _: std.Io, file: boot.File) !?[]const u8 {
        const self: *Esp = @ptrCast(@alignCast(ctx));
        try self.verifyMapping();
        const target = try self.path(file);
        defer self.a.free(target);
        const h = n.valid(n.k.CreateFileW(target, @bitCast(n.GENERIC_READ), .{ .READ = 1 }, null, .OPEN_EXISTING, .{ .FILE_FLAG_OPEN_REPARSE_POINT = 1 }, null)) orelse {
            if (n.k.GetLastError() == .ERROR_FILE_NOT_FOUND) return null;
            return error.StagedArtifactUnavailable;
        };
        defer n.close(h);
        try regular(h);
        const size = try fileSize(h);
        if (size == 0 or size > limit(file)) return error.StagedArtifactTooLarge;
        const bytes = try a.alloc(u8, @intCast(size));
        errdefer a.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            var count: u32 = 0;
            if (n.k.ReadFile(h, bytes[offset..].ptr, @intCast(@min(bytes.len - offset, 65536)), &count, null) == 0 or count == 0) return error.StagedArtifactReadFailed;
            offset += count;
        }
        return staging.decode(a, file, bytes, self.session_id, self.disk_identity);
    }
};

fn directory(a: std.mem.Allocator, path: []const u8) !n.f.HANDLE {
    const h = n.valid(n.k.CreateFileW(try n.wide(a, path), @bitCast(n.GENERIC_READ), .{ .READ = 1, .WRITE = 1 }, null, .OPEN_EXISTING, .{ .FILE_FLAG_BACKUP_SEMANTICS = 1, .FILE_FLAG_OPEN_REPARSE_POINT = 1 }, null)) orelse return error.EspDirectoryUnavailable;
    errdefer n.close(h);
    var info: n.fs.BY_HANDLE_FILE_INFORMATION = undefined;
    if (n.k.GetFileInformationByHandle(h, &info) == 0) return error.EspDirectoryUnavailable;
    const flags: n.fs.FILE_FLAGS_AND_ATTRIBUTES = @bitCast(info.dwFileAttributes);
    if (flags.FILE_ATTRIBUTE_REPARSE_POINT != 0 or flags.FILE_ATTRIBUTE_DIRECTORY == 0) return error.UnsafeEspDirectory;
    return h;
}
fn regular(h: n.f.HANDLE) !void {
    var info: n.fs.BY_HANDLE_FILE_INFORMATION = undefined;
    if (n.k.GetFileInformationByHandle(h, &info) == 0 or info.nNumberOfLinks != 1) return error.UnsafeEspFile;
    const flags: n.fs.FILE_FLAGS_AND_ATTRIBUTES = @bitCast(info.dwFileAttributes);
    if (flags.FILE_ATTRIBUTE_REPARSE_POINT != 0 or flags.FILE_ATTRIBUTE_SPARSE_FILE != 0 or flags.FILE_ATTRIBUTE_COMPRESSED != 0 or flags.FILE_ATTRIBUTE_DIRECTORY != 0) return error.UnsafeEspFile;
}
fn fileSize(h: n.f.HANDLE) !u64 {
    var size: n.win32.foundation.LARGE_INTEGER = undefined;
    if (n.k.GetFileSizeEx(h, &size) == 0 or size.QuadPart < 0) return error.InvalidEspFileSize;
    return @intCast(size.QuadPart);
}
fn writeAll(h: n.f.HANDLE, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var count: u32 = 0;
        if (n.k.WriteFile(h, bytes[offset..].ptr, @intCast(@min(bytes.len - offset, 65536)), &count, null) == 0 or count == 0) return error.EspWriteFailed;
        offset += count;
    }
}
fn findVolume(a: std.mem.Allocator, number: u32, offset: u64, length: u64) ![]const u8 {
    var buffer: [1024:0]u16 = @splat(0);
    const search = n.k.FindFirstVolumeW(&buffer, buffer.len);
    if (search == -1) return error.EspVolumeNotFound;
    defer _ = n.k.FindVolumeClose(search);
    var found: ?[]const u8 = null;
    while (true) {
        const volume = try std.unicode.utf16LeToUtf8Alloc(a, std.mem.sliceTo(&buffer, 0));
        if (n.simpleVolume(a, volume, number, offset, length)) {
            if (found != null) return error.AmbiguousEspVolume;
            found = volume;
        }
        if (n.k.FindNextVolumeW(search, &buffer, buffer.len) == 0) {
            if (n.k.GetLastError() != .ERROR_NO_MORE_FILES) return error.EspVolumeEnumerationFailed;
            break;
        }
    }
    return found orelse error.EspVolumeNotFound;
}

test "ESP names are fixed and boot path session components remain FAT short names" {
    const a = std.testing.allocator;
    const id = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    try std.testing.expect(@import("../../execution/worker.zig").validId(id));
    for (0..8) |i| {
        const component = try std.ascii.allocUpperString(a, id[i * 8 ..][0..8]);
        defer a.free(component);
        try std.testing.expectEqual(8, component.len);
        for (component) |ch| try std.testing.expect(std.ascii.isHex(ch) and !std.ascii.isLower(ch));
    }
    try std.testing.expectEqualStrings("SESSION.BIN", filename(.manifest));
    try std.testing.expectEqualStrings("RECEIPT.BIN", filename(.receipt));
}

test "ESP staging validates reservations before any Windows access" {
    var stage: Esp = undefined;
    try std.testing.expectError(error.InvalidStageReservation, stage.reserve(.image, 0));
    try std.testing.expectError(error.InvalidStageReservation, stage.reserve(.receipt, 2 * 1024 * 1024 + 1));
    const port = stage.store();
    try std.testing.expectError(error.StagedArtifactTooLarge, port.publish(port.context, std.testing.io, .manifest, ""));
    // Retain the read path for cross-compilation without touching a real ESP.
    std.mem.doNotOptimizeAway(&port);
    const open_fn = Esp.open;
    std.mem.doNotOptimizeAway(&open_fn);
}
