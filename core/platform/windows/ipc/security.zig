//! Authenticate local processes and secure durable records using kernel objects.
const std = @import("std");
const native = @import("../native.zig");
const win = native.win32;
const sec = win.security;
const adv = win.advapi32;
pub const Identity = struct { sid: []const u8, session: u32, elevated: bool };

pub fn identity(a: std.mem.Allocator, process: ?native.foundation.HANDLE) !Identity {
    var token: ?native.foundation.HANDLE = null;
    if (adv.OpenProcessToken(process, .{ .QUERY = 1 }, &token) == 0) return error.ProcessTokenUnavailable;
    defer _ = native.kernel32.CloseHandle(token.?);
    var needed: u32 = 0;
    _ = adv.GetTokenInformation(token, .TokenUser, null, 0, &needed);
    if (needed == 0 or needed > 65536) return error.InvalidProcessToken;
    const buffer = try a.alignedAlloc(u8, .of(sec.TOKEN_USER), needed);
    defer a.free(buffer);
    if (adv.GetTokenInformation(token, .TokenUser, buffer.ptr, needed, &needed) == 0) return error.ProcessTokenUnavailable;
    const user: *const sec.TOKEN_USER = @ptrCast(buffer.ptr);
    var sid: ?[*:0]u16 = null;
    if (adv.ConvertSidToStringSidW(user.User.Sid, &sid) == 0) return error.InvalidProcessToken;
    defer _ = native.kernel32.LocalFree(@bitCast(@intFromPtr(sid.?)));
    var elevation: sec.TOKEN_ELEVATION = undefined;
    if (adv.GetTokenInformation(token, .TokenElevation, &elevation, @sizeOf(@TypeOf(elevation)), &needed) == 0) return error.ProcessTokenUnavailable;
    var session: u32 = 0;
    if (adv.GetTokenInformation(token, .TokenSessionId, &session, @sizeOf(u32), &needed) == 0) return error.ProcessTokenUnavailable;
    return .{ .sid = try std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(sid.?)), .session = session, .elevated = elevation.TokenIsElevated != 0 };
}
pub fn elevated() bool {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    return (identity(arena.allocator(), native.kernel32.GetCurrentProcess()) catch return false).elevated;
}
pub fn executable(a: std.mem.Allocator, process: ?native.foundation.HANDLE) ![:0]const u16 {
    const path = try a.allocSentinel(u16, 32768, 0);
    var length: u32 = @intCast(path.len);
    if (native.kernel32.QueryFullProcessImageNameW(process, .WIN32, path, &length) == 0 or length == 0) return error.ExecutableUnavailable;
    path[length] = 0;
    return path[0..length :0];
}
fn fileIdentity(path: [:0]const u16) !win.storage.file_system.BY_HANDLE_FILE_INFORMATION {
    const h = native.kernel32.CreateFileW(path, .{ .READ_CONTROL = 1 }, .{ .READ = 1, .WRITE = 1, .DELETE = 1 }, null, .OPEN_EXISTING, .{}, null);
    if (h == native.foundation.INVALID_HANDLE_VALUE) return error.ExecutableUnavailable;
    defer _ = native.kernel32.CloseHandle(h);
    var info: win.storage.file_system.BY_HANDLE_FILE_INFORMATION = undefined;
    if (native.kernel32.GetFileInformationByHandle(h, &info) == 0) return error.ExecutableUnavailable;
    return info;
}
pub fn peer(a: std.mem.Allocator, pid: u32, owner: Identity, require_elevated: bool) !void {
    const process = native.kernel32.OpenProcess(.{ .QUERY_LIMITED_INFORMATION = 1 }, 0, pid) orelse return error.PeerUnavailable;
    defer _ = native.kernel32.CloseHandle(process);
    const other = try identity(a, process);
    if (owner.session != other.session or !std.mem.eql(u8, owner.sid, other.sid) or (require_elevated and !other.elevated)) return error.UnauthorizedPeer;
    const ours = try fileIdentity(try executable(a, native.kernel32.GetCurrentProcess()));
    const theirs = try fileIdentity(try executable(a, process));
    if (ours.dwVolumeSerialNumber != theirs.dwVolumeSerialNumber or ours.nFileIndexHigh != theirs.nFileIndexHigh or ours.nFileIndexLow != theirs.nFileIndexLow) return error.ExecutableChanged;
}
pub fn pipeName(a: std.mem.Allocator, owner: Identity) ![:0]const u16 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(owner.sid);
    hash.update(std.mem.asBytes(&owner.session));
    return native.wide(a, try a.print("\\\\.\\pipe\\Pizza-{s}", .{std.fmt.bytesToHex(hash.finalResult(), .lower)}));
}

pub const Descriptor = struct {
    ptr: sec.PSECURITY_DESCRIPTOR,
    pub fn init(a: std.mem.Allocator, sddl: []const u8) !Descriptor {
        const text = try native.wide(a, sddl);
        defer a.free(text);
        var ptr: ?sec.PSECURITY_DESCRIPTOR = null;
        if (adv.ConvertStringSecurityDescriptorToSecurityDescriptorW(text, 1, &ptr, null) == 0) return error.SecurityDescriptorUnavailable;
        return .{ .ptr = ptr.? };
    }
    pub fn deinit(self: Descriptor) void {
        _ = native.kernel32.LocalFree(@bitCast(@intFromPtr(self.ptr)));
    }
    pub fn attributes(self: Descriptor) sec.SECURITY_ATTRIBUTES {
        return .{ .nLength = @sizeOf(sec.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = self.ptr, .bInheritHandle = 0 };
    }
};
pub const RECORD_SDDL = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)";

/// Validate the opened handle, never a path that can be replaced between checks.
pub fn recordAccess(a: std.mem.Allocator, h: native.foundation.HANDLE, directory: bool) !win.storage.file_system.BY_HANDLE_FILE_INFORMATION {
    var info: win.storage.file_system.BY_HANDLE_FILE_INFORMATION = undefined;
    if (native.kernel32.GetFileInformationByHandle(h, &info) == 0) return error.UnsafeSessionFile;
    const attributes: native.fs.FILE_FLAGS_AND_ATTRIBUTES = @bitCast(info.dwFileAttributes);
    if (attributes.FILE_ATTRIBUTE_REPARSE_POINT != 0 or (attributes.FILE_ATTRIBUTE_DIRECTORY != 0) != directory) return error.UnsafeSessionFile;
    var owner: ?native.foundation.PSID = null;
    var acl: ?*sec.ACL = null;
    var descriptor: ?sec.PSECURITY_DESCRIPTOR = null;
    const requested: sec.OBJECT_SECURITY_INFORMATION = .{ .OWNER_SECURITY_INFORMATION = 1, .DACL_SECURITY_INFORMATION = 1 };
    if (adv.GetSecurityInfo(h, .FILE_OBJECT, @bitCast(requested), &owner, null, &acl, null, &descriptor) != .NO_ERROR) return error.UnsafeSessionFile;
    defer _ = native.kernel32.LocalFree(@bitCast(@intFromPtr(descriptor.?)));
    if (adv.IsWellKnownSid(owner, .BuiltinAdministratorsSid) == 0 and adv.IsWellKnownSid(owner, .LocalSystemSid) == 0) return error.UnsafeSessionFile;
    const expected = try Descriptor.init(a, RECORD_SDDL);
    defer expected.deinit();
    var present: i32 = 0;
    var defaulted: i32 = 0;
    var expected_acl: ?*sec.ACL = null;
    if (adv.GetSecurityDescriptorDacl(expected.ptr, &present, &expected_acl, &defaulted) == 0 or present == 0 or acl == null or expected_acl == null) return error.UnsafeSessionFile;
    const actual_bytes: [*]const u8 = @ptrCast(acl.?);
    const expected_bytes: [*]const u8 = @ptrCast(expected_acl.?);
    if (acl.?.AclSize != expected_acl.?.AclSize or !std.mem.eql(u8, actual_bytes[0..acl.?.AclSize], expected_bytes[0..expected_acl.?.AclSize])) return error.UnsafeSessionFile;
    return info;
}
