//! Bounded file-descriptor I/O and local socket transport.
const std = @import("std");
const c = @import("libc");
pub const MAX_REQUEST = 4 * 1024 * 1024;
pub fn writeAll(fd: c_int, bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = c.write(fd, bytes[at..].ptr, bytes.len - at);
        if (n < 0 and c.__errno_location().* == c.EINTR) continue;
        if (n <= 0) return false;
        at += @intCast(n);
    }
    return true;
}
pub fn sendAll(fd: c_int, bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = c.send(fd, bytes[at..].ptr, bytes.len - at, c.MSG_NOSIGNAL);
        if (n < 0 and c.__errno_location().* == c.EINTR) continue;
        if (n <= 0) return false;
        at += @intCast(n);
    }
    return true;
}
pub fn readExact(fd: c_int, bytes: []u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = c.read(fd, bytes[at..].ptr, bytes.len - at);
        if (n < 0 and c.__errno_location().* == c.EINTR) continue;
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
        const n = c.read(fd, bytes[at..].ptr, bytes.len - at);
        if (n < 0 and c.__errno_location().* == c.EINTR) continue;
        if (n < 0) return error.ReadFailed;
        if (n == 0) return a.realloc(bytes, at);
        at += @intCast(n);
    }
    return error.RequestTooLarge;
}
pub fn deadline(fd: c_int) void {
    const timeout: c.struct_timeval = .{ .tv_sec = 60, .tv_usec = 0 };
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(@TypeOf(timeout)));
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &timeout, @sizeOf(@TypeOf(timeout)));
}
pub fn peerIs(fd: c_int, uid: c.uid_t) bool {
    var cred: c.struct_ucred = undefined;
    var length: c.socklen_t = @sizeOf(@TypeOf(cred));
    return c.getsockopt(fd, c.SOL_SOCKET, c.SO_PEERCRED, &cred, &length) == 0 and length == @sizeOf(@TypeOf(cred)) and cred.uid == uid;
}
pub fn address(path: []const u8) !c.struct_sockaddr_un {
    var result: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    if (path.len >= result.sun_path.len) return error.SocketPathTooLong;
    result.sun_family = c.AF_UNIX;
    @memcpy(result.sun_path[0..path.len], path);
    return result;
}
test "IPC rejects an oversized request and broken transport writes do not raise SIGPIPE" {
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &pair));
    defer _ = c.close(pair[0]);
    defer _ = c.close(pair[1]);
    try std.testing.expect(sendAll(pair[0], "123456789"));
    try std.testing.expectEqual(@as(c_int, 0), c.shutdown(pair[0], c.SHUT_WR));
    try std.testing.expectError(error.RequestTooLarge, readBounded(std.testing.allocator, pair[1], 8));
    try std.testing.expect(!sendAll(pair[0], "must not be sent"));
}
