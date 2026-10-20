//! Bounded DER decoding and certificate timestamps for the supported Sigstore profile.
const std = @import("std");
pub const Der = struct {
    tag: u8,
    raw: []const u8,
    data: []const u8,
    pub fn read(bytes: []const u8) !Der {
        if (bytes.len < 2 or bytes[0] & 31 == 31) return error.InvalidDer;
        var start: usize = 2;
        var len: usize = bytes[1];
        if (len & 128 != 0) {
            const count = len & 127;
            if (count == 0 or count > 3 or bytes.len < start + count or bytes[start] == 0) return error.InvalidDer;
            len = 0;
            for (bytes[start..][0..count]) |b| len = (len << 8) | b;
            if (len < 128) return error.InvalidDer;
            start += count;
        }
        if (len > bytes.len - start) return error.InvalidDer;
        return .{ .tag = bytes[0], .raw = bytes[0 .. start + len], .data = bytes[start..][0..len] };
    }
    pub fn one(bytes: []const u8, tag: u8) !Der {
        const v = try read(bytes);
        if (v.raw.len != bytes.len or v.tag != tag) return error.InvalidDer;
        return v;
    }
    pub fn take(bytes: *[]const u8, tag: u8) !Der {
        const v = try read(bytes.*);
        if (v.tag != tag) return error.InvalidDer;
        bytes.* = bytes.*[v.raw.len..];
        return v;
    }
};
pub fn wrap(a: std.mem.Allocator, tag: u8, bytes: []const u8) ![]const u8 {
    if (bytes.len > 0xffffff) return error.InvalidDer;
    var prefix: [5]u8 = undefined;
    prefix[0] = tag;
    const count: usize = if (bytes.len < 128) 0 else if (bytes.len <= 255) 1 else if (bytes.len <= 65535) 2 else 3;
    prefix[1] = if (count == 0) @intCast(bytes.len) else 0x80 | @as(u8, @intCast(count));
    for (0..count) |i| prefix[2 + i] = @truncate(bytes.len >> @as(u5, @intCast(8 * (count - i - 1))));
    return std.mem.concat(a, u8, &.{ prefix[0 .. 2 + count], bytes });
}
pub fn timestamp(bytes: []const u8) !u64 {
    // Trust-root RFC3339 timestamps only; discard fractional precision conservatively.
    if (bytes.len < 20 or bytes[4] != '-' or bytes[7] != '-' or bytes[10] != 'T' or bytes[13] != ':' or bytes[16] != ':' or bytes[bytes.len - 1] != 'Z') return error.InvalidTimestamp;
    var content: [15]u8 = undefined;
    var n: usize = 0;
    for (bytes[0..19]) |b| if (std.ascii.isDigit(b)) {
        content[n] = b;
        n += 1;
    };
    if (n != 14) return error.InvalidTimestamp;
    content[14] = 'Z';
    return certTime(.{ .tag = 0x18, .raw = &content, .data = &content });
}
pub fn certTime(v: Der) !u64 {
    if ((v.tag != 0x17 or v.data.len != 13) and (v.tag != 0x18 or v.data.len != 15)) return error.InvalidTimestamp;
    if (v.data[v.data.len - 1] != 'Z') return error.InvalidTimestamp;
    for (v.data[0 .. v.data.len - 1]) |b| if (!std.ascii.isDigit(b)) return error.InvalidTimestamp;
    return std.crypto.Certificate.parseTime(.{ .buffer = v.data, .index = 0 }, .{ .identifier = @bitCast(v.tag), .slice = .{ .start = 0, .end = @intCast(v.data.len) } });
}
