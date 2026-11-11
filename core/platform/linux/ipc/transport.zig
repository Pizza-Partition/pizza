//! Bounded file-descriptor I/O and local socket transport.
const std = @import("std");
const libc = @import("libc");
pub const MAX_REQUEST = 4 * 1024 * 1024;
pub fn writeAll(fd: c_int, bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = libc.write(fd, bytes[at..].ptr, bytes.len - at);
        if (n < 0 and libc.__errno_location().* == libc.EINTR) continue;
        if (n <= 0) return false;
        at += @intCast(n);
    }
    return true;
}
pub fn sendAll(fd: c_int, bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = libc.send(fd, bytes[at..].ptr, bytes.len - at, libc.MSG_NOSIGNAL);
        if (n < 0 and libc.__errno_location().* == libc.EINTR) continue;
        if (n <= 0) return false;
        at += @intCast(n);
    }
    return true;
}
pub fn readExact(fd: c_int, bytes: []u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = libc.read(fd, bytes[at..].ptr, bytes.len - at);
        if (n < 0 and libc.__errno_location().* == libc.EINTR) continue;
        if (n <= 0) return false;
        at += @intCast(n);
    }
    return true;
}
pub fn readBounded(a: std.mem.Allocator, fd: c_int, limit: usize) ![]u8 {
    const bytes = try a.alloc(u8, limit);
    errdefer a.free(bytes);
    var at: usize = 0;
    while (at < limit) {
        const n = libc.read(fd, bytes[at..].ptr, bytes.len - at);
        if (n < 0 and libc.__errno_location().* == libc.EINTR) continue;
        if (n < 0) return error.ReadFailed;
        if (n == 0) return a.realloc(bytes, at);
        at += @intCast(n);
    }
    return error.RequestTooLarge;
}
pub fn deadline(fd: c_int) !void {
    const timeout: libc.struct_timeval = .{ .tv_sec = 60, .tv_usec = 0 };
    if (libc.setsockopt(fd, libc.SOL_SOCKET, libc.SO_RCVTIMEO, &timeout, @sizeOf(@TypeOf(timeout))) != 0 or
        libc.setsockopt(fd, libc.SOL_SOCKET, libc.SO_SNDTIMEO, &timeout, @sizeOf(@TypeOf(timeout))) != 0) return error.SocketTimeoutUnavailable;
}
pub fn peerIs(fd: c_int, uid: libc.uid_t) bool {
    var cred: libc.struct_ucred = undefined;
    var length: libc.socklen_t = @sizeOf(@TypeOf(cred));
    return libc.getsockopt(fd, libc.SOL_SOCKET, libc.SO_PEERCRED, &cred, &length) == 0 and length == @sizeOf(@TypeOf(cred)) and cred.uid == uid;
}
pub fn address(path: []const u8) !libc.struct_sockaddr_un {
    var result: libc.struct_sockaddr_un = std.mem.zeroes(libc.struct_sockaddr_un);
    if (path.len >= result.sun_path.len) return error.SocketPathTooLong;
    result.sun_family = libc.AF_UNIX;
    @memcpy(result.sun_path[0..path.len], path);
    return result;
}
test "IPC rejects an oversized request and broken transport writes do not raise SIGPIPE" {
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), libc.socketpair(libc.AF_UNIX, libc.SOCK_STREAM | libc.SOCK_CLOEXEC, 0, &pair));
    defer _ = libc.close(pair[0]);
    defer _ = libc.close(pair[1]);
    try std.testing.expect(sendAll(pair[0], "123456789"));
    try std.testing.expectEqual(@as(c_int, 0), libc.shutdown(pair[0], libc.SHUT_WR));
    try std.testing.expectError(error.RequestTooLarge, readBounded(std.testing.allocator, pair[1], 8));
    try std.testing.expect(!sendAll(pair[0], "must not be sent"));
}

test "socket deadline setup propagates failure instead of leaving an unbounded connection" {
    try std.testing.expectError(error.SocketTimeoutUnavailable, deadline(-1));
}
