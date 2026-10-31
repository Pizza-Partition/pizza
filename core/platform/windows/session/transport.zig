//! Bounded byte framing over local, nonblocking named pipes.
const std = @import("std");
const n = @import("../native.zig");
pub const REQUEST_LIMIT = 4 * 1024 * 1024;
pub const RESPONSE_LIMIT = 8 * 1024 * 1024;
pub fn deadline() u64 {
    return n.k.GetTickCount64() + 60_000;
}
pub fn readExact(h: n.f.HANDLE, bytes: []u8, until: u64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var count: u32 = 0;
        if (n.k.ReadFile(h, bytes[offset..].ptr, @intCast(bytes.len - offset), &count, null) == 0) {
            const code = n.k.GetLastError();
            if (code != .ERROR_NO_DATA and code != .ERROR_PIPE_LISTENING) return error.PipeReadFailed;
        }
        offset += count;
        if (offset == bytes.len) break;
        if (n.k.GetTickCount64() >= until) return error.PipeTimeout;
        if (count == 0) n.k.Sleep(10);
    }
}
pub fn writeAll(h: n.f.HANDLE, bytes: []const u8, until: u64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var count: u32 = 0;
        if (n.k.WriteFile(h, bytes[offset..].ptr, @intCast(bytes.len - offset), &count, null) == 0) return error.PipeWriteFailed;
        offset += count;
        if (offset == bytes.len) break;
        if (n.k.GetTickCount64() >= until) return error.PipeTimeout;
        if (count == 0) n.k.Sleep(10);
    }
}
pub fn receive(a: std.mem.Allocator, h: n.f.HANDLE, limit: usize) ![]const u8 {
    const until = deadline();
    var header: [4]u8 = undefined;
    try readExact(h, &header, until);
    const size = std.mem.readInt(u32, &header, .little);
    if (size == 0 or size > limit) return error.InvalidPipeFrame;
    const bytes = try a.alloc(u8, size);
    errdefer a.free(bytes);
    try readExact(h, bytes, until);
    return bytes;
}
pub fn send(h: n.f.HANDLE, bytes: []const u8, limit: usize) !void {
    if (bytes.len == 0 or bytes.len > limit) return error.InvalidPipeFrame;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(bytes.len), .little);
    const until = deadline();
    try writeAll(h, &header, until);
    try writeAll(h, bytes, until);
}
