//! Administrator-owned records, atomically replaced after flushing their contents.
const Store = @This();
const std = @import("std");
const native = @import("../native.zig");
const security = @import("security.zig");
const isSessionId = @import("../../../execution/worker.zig").isSessionId;
const MAX_RECORD = 4 * 1024 * 1024;
path: ?[]const u8 = null,
namespace: enum { sessions, maintenance } = .sessions,
directories: [3]?native.foundation.HANDLE = .{ null, null, null },

pub fn openMaintenance(a: std.mem.Allocator) !Store {
    var store: Store = .{ .namespace = .maintenance };
    try store.init(a, try security.identity(a, native.kernel32.GetCurrentProcess()));
    return store;
}

pub fn init(self: *Store, a: std.mem.Allocator, owner: security.Identity) !void {
    if (!owner.elevated) return error.AdministratorRequired;
    var folder: ?[*:0]u16 = null;
    if (native.win32.shell32.SHGetKnownFolderPath(&native.win32.ui.shell.FOLDERID_ProgramData, .DEFAULT, null, &folder).failed) return error.SessionDirectoryUnavailable;
    defer native.win32.ole32.CoTaskMemFree(@ptrCast(folder.?));
    const base = try std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(folder.?));
    const descriptor = try security.Descriptor.init(a, security.RECORD_SDDL);
    defer descriptor.deinit();
    var attributes = descriptor.attributes();
    errdefer self.deinit();
    var path = base;
    for ([_][]const u8{ "Pizza", @tagName(self.namespace), owner.sid }, 0..) |segment, index| {
        path = try a.print("{s}\\{s}", .{ path, segment });
        const wide = try native.wide(a, path);
        if (native.kernel32.CreateDirectoryW(wide, &attributes) == 0 and native.kernel32.GetLastError() != .ERROR_ALREADY_EXISTS) return error.SessionDirectoryUnavailable;
        // Keep each ancestor open without delete sharing so it cannot be renamed.
        const h = native.kernel32.CreateFileW(wide, .{ .READ_CONTROL = 1 }, .{ .READ = 1, .WRITE = 1 }, null, .OPEN_EXISTING, .{ .FILE_FLAG_BACKUP_SEMANTICS = 1, .FILE_FLAG_OPEN_REPARSE_POINT = 1 }, null);
        if (h == native.foundation.INVALID_HANDLE_VALUE) return error.SessionDirectoryUnavailable;
        self.directories[index] = h;
        _ = try security.recordAccess(a, h, true);
    }
    self.path = path;
}
pub fn deinit(self: *Store) void {
    for (&self.directories) |*h| {
        if (h.*) |handle| _ = native.kernel32.CloseHandle(handle);
        h.* = null;
    }
    self.path = null;
}
fn filename(self: *Store, a: std.mem.Allocator, id: []const u8) ![:0]const u16 {
    if (!isSessionId(id)) return error.InvalidSession;
    return native.wide(a, try a.print("{s}\\{s}.json", .{ self.path orelse return error.SessionUnavailable, id }));
}
pub fn persist(self: *Store, id: []const u8, bytes: []const u8) !void {
    if (bytes.len > MAX_RECORD) return error.InvalidSession;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const destination = try self.filename(a, id);
    var random: [16]u8 = undefined;
    if (native.win32.advapi32.SystemFunction036(&random, random.len) == 0) return error.RandomUnavailable;
    const temporary = try native.wide(a, try a.print("{s}\\{s}.{s}.tmp", .{ self.path.?, id, std.fmt.bytesToHex(random, .lower) }));
    const descriptor = try security.Descriptor.init(a, security.RECORD_SDDL);
    defer descriptor.deinit();
    var attributes = descriptor.attributes();
    const h = native.kernel32.CreateFileW(temporary, @bitCast(native.GENERIC_WRITE), .{}, &attributes, .CREATE_NEW, .{ .FILE_FLAG_WRITE_THROUGH = 1 }, null);
    if (h == native.foundation.INVALID_HANDLE_VALUE) return error.SessionSyncFailed;
    var closed = false;
    var replaced = false;
    defer {
        if (!closed) _ = native.kernel32.CloseHandle(h);
        if (!replaced) _ = native.kernel32.DeleteFileW(temporary);
    }
    var offset: usize = 0;
    while (offset < bytes.len) {
        var count: u32 = 0;
        if (native.kernel32.WriteFile(h, bytes[offset..].ptr, @intCast(bytes.len - offset), &count, null) == 0 or count == 0) return error.SessionSyncFailed;
        offset += count;
    }
    if (native.kernel32.FlushFileBuffers(h) == 0) return error.SessionSyncFailed;
    _ = native.kernel32.CloseHandle(h);
    closed = true;
    if (native.kernel32.MoveFileExW(temporary, destination, .{ .REPLACE_EXISTING = 1, .WRITE_THROUGH = 1 }) == 0) return error.SessionSyncFailed;
    replaced = true;
}
pub fn read(self: *Store, a: std.mem.Allocator, id: []const u8) !?[]const u8 {
    const path = try self.filename(a, id);
    defer a.free(path);
    const access = native.GENERIC_READ | @as(u32, @bitCast(native.fs.READ_CONTROL));
    const h = native.kernel32.CreateFileW(path, @bitCast(access), .{ .READ = 1, .DELETE = 1 }, null, .OPEN_EXISTING, .{ .FILE_FLAG_OPEN_REPARSE_POINT = 1 }, null);
    if (h == native.foundation.INVALID_HANDLE_VALUE) return switch (native.kernel32.GetLastError()) {
        .ERROR_FILE_NOT_FOUND, .ERROR_PATH_NOT_FOUND => null,
        else => error.SessionRecordUnavailable,
    };
    defer _ = native.kernel32.CloseHandle(h);
    const info = try security.recordAccess(a, h, false);
    if (info.nFileSizeHigh != 0 or info.nFileSizeLow > MAX_RECORD) return error.UnsafeSessionRecord;
    const bytes = try a.alloc(u8, info.nFileSizeLow);
    errdefer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        var count: u32 = 0;
        if (native.kernel32.ReadFile(h, bytes[offset..].ptr, @intCast(bytes.len - offset), &count, null) == 0 or count == 0) {
            return error.SessionRecordReadFailed;
        }
        offset += count;
    }
    return bytes;
}
pub fn latest(self: *Store, a: std.mem.Allocator) !?[]const u8 {
    const pattern = try native.wide(a, try a.print("{s}\\*.json", .{self.path orelse return null}));
    defer a.free(pattern);
    var entry: native.win32.storage.file_system.WIN32_FIND_DATAW = undefined;
    const h = native.kernel32.FindFirstFileW(pattern, &entry);
    if (h == -1) return if (native.kernel32.GetLastError() == .ERROR_FILE_NOT_FOUND) null else error.SessionDirectoryUnavailable;
    defer _ = native.kernel32.FindClose(h);
    var newest: u64 = 0;
    var id: ?[64]u8 = null;
    var count: usize = 0;
    while (true) {
        count += 1;
        if (count > 100_000) return error.TooManySessions;
        const name = std.mem.sliceTo(&entry.cFileName, 0);
        if (name.len == 69 and std.mem.eql(u16, name[64..], native.wideLiteral(".json"))) {
            var candidate: [64]u8 = undefined;
            for (&candidate, name[0..64]) |*byte, ch| byte.* = std.math.cast(u8, ch) orelse 0;
            const time = @as(u64, entry.ftLastWriteTime.dwHighDateTime) << 32 | entry.ftLastWriteTime.dwLowDateTime;
            if (isSessionId(&candidate) and (id == null or time > newest or (time == newest and std.mem.order(u8, &candidate, &id.?) == .gt))) {
                const bytes = try self.read(a, &candidate);
                if (bytes) |data| {
                    a.free(data);
                    newest = time;
                    id = candidate;
                }
            }
        }
        if (native.kernel32.FindNextFileW(h, &entry) == 0) {
            if (native.kernel32.GetLastError() != .ERROR_NO_MORE_FILES) return error.SessionDirectoryUnavailable;
            break;
        }
    }
    return if (id) |value| try a.dupe(u8, &value) else null;
}
