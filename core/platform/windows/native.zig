//! Windows handles and bounded, typed disk-layout IOCTLs.
const std = @import("std");
pub const win32 = @import("win32");
pub const kernel32 = win32.kernel32;
pub const foundation = win32.foundation;
pub const fs = win32.storage.file_system;
pub const GENERIC_READ = win32.system.system_services.GENERIC_READ;
pub const GENERIC_WRITE = win32.system.system_services.GENERIC_WRITE;
pub const PIPE_SERVER_FLAGS: fs.FILE_FLAGS_AND_ATTRIBUTES = @bitCast(@as(u32, @bitCast(fs.PIPE_ACCESS_DUPLEX)) | @as(u32, @bitCast(fs.FILE_FLAG_FIRST_PIPE_INSTANCE)));
pub const wide = std.unicode.utf8ToUtf16LeAllocZ;
pub const wideLiteral = std.unicode.utf8ToUtf16LeStringLiteral;

/// Enable a privilege on a temporary thread token. Never change the process
/// token: other request/worker threads must not inherit firmware/shutdown access.
pub const Privilege = struct {
    pub const Kind = enum { uefi, shutdown, volume };

    pub fn enable(kind: Kind) !Privilege {
        const adv = win32.advapi32;
        var existing: ?foundation.HANDLE = null;
        if (adv.OpenThreadToken(kernel32.GetCurrentThread(), .{ .QUERY = 1 }, 1, &existing) != 0) {
            if (existing) |h| _ = kernel32.CloseHandle(h);
            return error.ThreadAlreadyImpersonating;
        }

        // ERROR_NO_TOKEN is expected if the thread has no token, but other errors are fatal.
        if (kernel32.GetLastError() != .ERROR_NO_TOKEN) return error.PrivilegeUnavailable;
        if (adv.ImpersonateSelf(.Impersonation) == 0) return error.PrivilegeUnavailable;
        errdefer if (adv.RevertToSelf() == 0) @panic("Cannot restore Windows thread token");

        var token: ?foundation.HANDLE = null;
        if (adv.OpenThreadToken(kernel32.GetCurrentThread(), .{ .QUERY = 1, .ADJUST_PRIVILEGES = 1 }, 1, &token) == 0)
            return error.PrivilegeUnavailable;
        const handle = token orelse return error.PrivilegeUnavailable;

        defer _ = kernel32.CloseHandle(handle);
        var requested = std.mem.zeroes(win32.security.TOKEN_PRIVILEGES);
        requested.PrivilegeCount = 1;
        requested.Privileges[0].Attributes = .{ .ENABLED = 1 };
        const name = switch (kind) {
            .uefi => wideLiteral("SeSystemEnvironmentPrivilege"),
            .shutdown => wideLiteral("SeShutdownPrivilege"),
            .volume => wideLiteral("SeManageVolumePrivilege"),
        };
        if (adv.LookupPrivilegeValueW(null, name, &requested.Privileges[0].Luid) == 0) return error.PrivilegeUnavailable;
        if (adv.AdjustTokenPrivileges(handle, 0, &requested, 0, null, null) == 0 or kernel32.GetLastError() != .NO_ERROR)
            return error.PrivilegeUnavailable;
        return .{};
    }

    pub fn deinit(self: *Privilege) void {
        // A failed revert is a security boundary failure, never a recoverable
        // request error after which this thread may process another caller.
        if (win32.advapi32.RevertToSelf() == 0) @panic("Cannot restore Windows thread token");
        self.* = undefined;
    }
};
pub fn open(a: std.mem.Allocator, path: []const u8, access: u32) !foundation.HANDLE {
    const p = try wide(a, path);
    defer a.free(p);
    const handle = kernel32.CreateFileW(p, @bitCast(access), .{ .READ = 1, .WRITE = 1, .DELETE = 1 }, null, .OPEN_EXISTING, .{}, null);
    if (handle == foundation.INVALID_HANDLE_VALUE) return error.WindowsDeviceOpenFailed;
    return handle;
}
pub fn ioctl(handle: foundation.HANDLE, code: u32, output: []u8) !usize {
    var returned: u32 = 0;
    if (kernel32.DeviceIoControl(handle, code, null, 0, output.ptr, @intCast(output.len), &returned, null) == 0) return error.WindowsIoctlFailed;
    if (returned > output.len) return error.InvalidWindowsResponse;
    return returned;
}

const api = win32.system.ioctl;
pub const Layout = struct {
    memory: []align(@alignOf(api.DRIVE_LAYOUT_INFORMATION_EX)) u8,
    header: *const api.DRIVE_LAYOUT_INFORMATION_EX,
    entries: []const api.PARTITION_INFORMATION_EX,
    pub fn deinit(self: Layout, a: std.mem.Allocator) void {
        a.free(self.memory);
    }
};
pub fn readLayout(a: std.mem.Allocator, handle: foundation.HANDLE) !Layout {
    var size: usize = 4096;
    while (size <= 1024 * 1024) : (size *= 2) {
        const bytes = try a.alignedAlloc(u8, .of(api.DRIVE_LAYOUT_INFORMATION_EX), size);
        var returned: u32 = 0;
        if (kernel32.DeviceIoControl(handle, api.IOCTL_DISK_GET_DRIVE_LAYOUT_EX, null, 0, bytes.ptr, @intCast(bytes.len), &returned, null) == 0) {
            a.free(bytes);
            const err = kernel32.GetLastError();
            if (err == .ERROR_INSUFFICIENT_BUFFER or err == .ERROR_MORE_DATA) continue;
            return error.WindowsLayoutUnavailable;
        }
        errdefer a.free(bytes);
        const offset = @offsetOf(api.DRIVE_LAYOUT_INFORMATION_EX, "PartitionEntry");
        if (returned < offset or returned > bytes.len) return error.InvalidWindowsDiskLayout;
        const header: *const api.DRIVE_LAYOUT_INFORMATION_EX = @ptrCast(bytes.ptr);
        if (header.PartitionCount > 4096 or offset + @as(u64, header.PartitionCount) * @sizeOf(api.PARTITION_INFORMATION_EX) > returned) return error.InvalidWindowsDiskLayout;
        const entries: [*]const api.PARTITION_INFORMATION_EX = @ptrCast(@alignCast(bytes[offset..].ptr));
        return .{ .memory = bytes, .header = header, .entries = entries[0..header.PartitionCount] };
    }
    return error.WindowsLayoutTooLarge;
}
pub fn guid(a: std.mem.Allocator, value: win32.zig.Guid) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(std.mem.asBytes(&value).*, .lower));
}
pub const Gpt = struct {
    info: @import("../../planning/gpt.zig").Table,
    bytes: []align(4096) u8,
    pub fn deinit(self: Gpt, a: std.mem.Allocator) void {
        a.free(self.bytes);
    }
};
fn readDisk(handle: foundation.HANDLE, offset: u64, bytes: []u8) !void {
    if (offset > std.math.maxInt(i64) or kernel32.SetFilePointerEx(handle, .{ .QuadPart = @intCast(offset) }, null, .BEGIN) == 0) return error.WindowsGptUnavailable;
    var count: u32 = 0;
    if (kernel32.ReadFile(handle, bytes.ptr, @intCast(bytes.len), &count, null) == 0 or count != bytes.len) return error.WindowsGptUnavailable;
}
pub fn readGpt(a: std.mem.Allocator, handle: foundation.HANDLE, sector: u32, capacity: u64) !Gpt {
    if (sector < 512 or sector > 4096) return error.InvalidGpt;
    var header: [4096]u8 align(4096) = undefined;
    try readDisk(handle, sector, header[0..sector]);
    const info = try @import("../../planning/gpt.zig").table(header[0..sector], sector, capacity);
    const bytes = try a.alignedAlloc(u8, .fromByteUnits(4096), std.mem.alignForward(usize, info.entries_bytes, sector));
    errdefer a.free(bytes);
    if (bytes.len > capacity - info.offset_bytes) return error.InvalidGpt;
    try readDisk(handle, info.offset_bytes, bytes);
    if (std.hash.Crc32.hash(bytes[0..info.entries_bytes]) != info.checksum) return error.InvalidGpt;
    return .{ .info = info, .bytes = bytes };
}
pub fn deviceNumber(handle: foundation.HANDLE) !u32 {
    var number: api.STORAGE_DEVICE_NUMBER = undefined;
    if (try ioctl(handle, api.IOCTL_STORAGE_GET_DEVICE_NUMBER, std.mem.asBytes(&number)) < @sizeOf(@TypeOf(number))) return error.InvalidWindowsResponse;
    return number.DeviceNumber;
}

/// Bound every descriptor offset before reading it. Restrict cross-OS identity
/// to device-associated binary NAA/EUI identifiers; port and adapter IDs do not
/// identify the disk, and WMI UniqueId formatting is provider-specific.
pub fn portableWwid(a: std.mem.Allocator, bytes: []const u8) !?[]const u8 {
    if (bytes.len < 12) return error.InvalidStorageIdentifiers;
    const size = std.mem.readInt(u32, bytes[4..8], .little);
    const count = std.mem.readInt(u32, bytes[8..12], .little);
    if (size < 12 or size > bytes.len or count > 1024) return error.InvalidStorageIdentifiers;
    var offset: usize = 12;
    var selected: ?[]const u8 = null;
    errdefer if (selected) |value| a.free(value);
    var priority: u8 = 0;
    for (0..count) |i| {
        if (offset > size or size - offset < 16) return error.InvalidStorageIdentifiers;
        const entry = bytes[offset..size];
        const code = std.mem.readInt(u32, entry[0..4], .little);
        const kind = std.mem.readInt(u32, entry[4..8], .little);
        const length = std.mem.readInt(u16, entry[8..10], .little);
        const next = std.mem.readInt(u16, entry[10..12], .little);
        const association = std.mem.readInt(u32, entry[12..16], .little);
        if (length > entry.len - 16) return error.InvalidStorageIdentifiers;
        if (code == 1 and association == 0 and (kind == 2 or kind == 3)) {
            const id = entry[16..][0..length];
            const rank: u8 = if (kind == 3) 2 else 1;
            const valid_length = if (kind == 3) length == 8 or length == 16 else length == 8 or length == 12 or length == 16;
            if (!valid_length or std.mem.allEqual(u8, id, 0)) return error.InvalidStorageIdentifiers;
            if (kind == 3 and id[0] >> 4 != 2 and id[0] >> 4 != 3 and id[0] >> 4 != 5 and id[0] >> 4 != 6) return error.InvalidStorageIdentifiers;
            if (kind == 3 and ((id[0] >> 4 == 6 and length != 16) or (id[0] >> 4 != 6 and length != 8))) return error.InvalidStorageIdentifiers;
            const hex = try a.alloc(u8, length * 2);
            defer a.free(hex);
            for (id, 0..) |byte, j| {
                hex[j * 2] = "0123456789abcdef"[byte >> 4];
                hex[j * 2 + 1] = "0123456789abcdef"[byte & 15];
            }
            const value = try std.mem.concat(a, u8, &.{ if (kind == 3) "naa." else "eui.", hex });
            var retained = false;
            defer if (!retained) a.free(value);
            if (rank == priority and selected != null and !std.mem.eql(u8, selected.?, value)) return error.AmbiguousStorageIdentity;
            if (rank > priority) {
                if (selected) |old| a.free(old);
                selected = value;
                retained = true;
                priority = rank;
            }
        }
        if (i + 1 < count) {
            if (next < 16 + @as(usize, length) or next > entry.len) return error.InvalidStorageIdentifiers;
            offset += next;
        } else if (next != 0 and (next < 16 + @as(usize, length) or next > entry.len)) return error.InvalidStorageIdentifiers;
    }
    return selected;
}

pub fn maintenanceIdentity(a: std.mem.Allocator, handle: foundation.HANDLE) !?[32]u8 {
    var query = std.mem.zeroes(api.STORAGE_PROPERTY_QUERY);
    query.PropertyId = .DeviceIdProperty;
    query.QueryType = .StandardQuery;
    const buffer = try a.alloc(u8, 65536);
    defer a.free(buffer);
    var size: u32 = 0;
    if (kernel32.DeviceIoControl(handle, api.IOCTL_STORAGE_QUERY_PROPERTY, &query, @sizeOf(@TypeOf(query)), buffer.ptr, @intCast(buffer.len), &size, null) == 0) {
        const code = kernel32.GetLastError();
        if (code == .ERROR_INVALID_FUNCTION or code == .ERROR_NOT_SUPPORTED or code == .ERROR_INVALID_PARAMETER) return null;
        return error.StorageIdentityUnavailable;
    }
    if (size > buffer.len) return error.InvalidStorageIdentifiers;
    const wwid = try portableWwid(a, buffer[0..size]) orelse return null;
    defer a.free(wwid);
    return try @import("../../planning/identity.zig").diskFromWwid(wwid);
}

pub fn simpleVolume(a: std.mem.Allocator, path: []const u8, disk_number: u32, offset: u64, length: u64) bool {
    const handle = open(a, std.mem.trimEnd(u8, path, "\\"), 0) catch return false;
    defer _ = kernel32.CloseHandle(handle);
    var extents: api.VOLUME_DISK_EXTENTS = undefined;
    const returned = ioctl(handle, win32.storage.file_system.IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, std.mem.asBytes(&extents)) catch return false;
    return returned >= @sizeOf(api.VOLUME_DISK_EXTENTS) and extents.NumberOfDiskExtents == 1 and
        extents.Extents[0].DiskNumber == disk_number and extents.Extents[0].StartingOffset.QuadPart == offset and extents.Extents[0].ExtentLength.QuadPart == length;
}
