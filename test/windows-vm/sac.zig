//! Bounded incremental serial text, independent of read/chunk boundaries.
const std = @import("std");
pub const Transcript = struct {
    bytes: std.ArrayList(u8) = .empty,
    pub fn append(t: *Transcript, a: std.mem.Allocator, bytes: []const u8) !void {
        if (t.bytes.items.len + bytes.len > 64 * 1024 * 1024) return error.ConsoleLimitExceeded;
        try t.bytes.appendSlice(a, bytes);
    }
    pub fn mark(t: Transcript) usize {
        return t.bytes.items.len;
    }
    pub fn since(t: Transcript, offset: usize) []const u8 {
        return t.bytes.items[@min(offset, t.bytes.items.len)..];
    }
    pub fn contains(t: Transcript, offset: usize, text: []const u8) bool {
        return std.mem.indexOf(u8, t.since(offset), text) != null;
    }
};
// CMD echoes its input. Only a complete standalone result line is a receipt.
pub fn result(bytes: []const u8, marker: []const u8) !?bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        // The last line may be a fragmented read: require its line terminator.
        if (lines.index == null and (bytes.len == 0 or bytes[bytes.len - 1] != '\n')) break;
        const clean = std.mem.trim(u8, line, "\r \t");
        if (!std.mem.startsWith(u8, clean, marker)) continue;
        const code = clean[marker.len..];
        if (std.mem.eql(u8, code, ":OK")) return true;
        if (std.mem.eql(u8, code, ":FAIL")) return false;
    }
    return null;
}
test "fragmented SAC prompts remain discoverable" {
    var t: Transcript = .{};
    defer t.bytes.deinit(std.testing.allocator);
    try t.append(std.testing.allocator, "old SAC>");
    const start = t.mark();
    try t.append(std.testing.allocator, "\r\nUser");
    try std.testing.expect(!t.contains(start, "Username:"));
    try t.append(std.testing.allocator, "name:");
    try std.testing.expect(t.contains(start, "Username:"));
    try std.testing.expect(!t.contains(start, "SAC>"));
}
test "command echo cannot impersonate completion" {
    try std.testing.expectEqual(@as(?bool, null), try result("C:\\>agent & echo PZ_123:OK\r\n", "PZ_123"));
    try std.testing.expectEqual(@as(?bool, null), try result("\r\nPZ_123:O", "PZ_123"));
    try std.testing.expectEqual(@as(?bool, true), try result("echo PZ_123:FAIL\r\nPZ_123:OK\r\n", "PZ_123"));
    try std.testing.expectEqual(@as(?bool, false), try result("PZ_123:FAIL\r\n", "PZ_123"));
}
