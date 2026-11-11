//! OS-independent ESP staging format and bounds shared with both native ports.
const std = @import("std");
const proto = @import("proto");
const boot = @import("ports.zig");
pub fn bootPath(a: std.mem.Allocator, session: []const u8) ![]const u8 {
    _ = try proto.hexDigest(session);
    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(a, "\\EFI\\Pizza");
    for (0..8) |i| {
        try result.append(a, '\\');
        for (session[i * 8 ..][0..8]) |ch| try result.append(a, std.ascii.toUpper(ch));
    }
    try result.appendSlice(a, "\\maint.efi");
    return result.toOwnedSlice(a);
}
pub fn filename(file: boot.File) [:0]const u8 {
    return switch (file) {
        .image => "maint.efi",
        .manifest => "SESSION.BIN",
        .lease => "LEASE.JSON",
        .receipt => "RECEIPT.BIN",
        .request => "REQUEST.BIN",
        .anchor => "ANCHOR.BIN",
    };
}
pub fn limit(file: boot.File) u64 {
    return switch (file) {
        .image, .anchor => 512 * 1024 * 1024,
        .manifest => boot.MAX_MANIFEST_BYTES,
        .lease => 1024 * 1024,
        .receipt => 2 * 1024 * 1024,
        .request => 4 * 1024 * 1024 + 4096,
    };
}
/// Takes ownership on success; the native port frees its buffer on failure.
pub fn decode(a: std.mem.Allocator, file: boot.File, bytes: []u8, session: boot.Digest, disk: boot.Digest) !?[]const u8 {
    if ((file == .lease or file == .receipt) and std.mem.allEqual(u8, bytes, 0)) {
        a.free(bytes);
        return null;
    }
    if (file == .receipt) {
        const envelope = try boot.decodeReceiptEnvelope(bytes);
        if (!std.mem.eql(u8, &envelope.session, &session) or !std.mem.eql(u8, &envelope.disk_identity, &disk)) return error.CompletionReceiptIdentityMismatch;
        const result = try a.dupe(u8, envelope.bytes);
        a.free(bytes);
        return result;
    }
    return bytes;
}

pub fn segments(a: std.mem.Allocator, session: []const u8) ![10][]const u8 {
    _ = try proto.hexDigest(session);
    var result: [10][]const u8 = undefined;
    result[0] = "EFI";
    result[1] = "Pizza";
    for (2..10) |i| result[i] = try std.ascii.allocUpperString(a, session[(i - 2) * 8 ..][0..8]);
    return result;
}

test "ESP names and bounds are identical on both platforms" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    const parts = try segments(a, id);
    try std.testing.expectEqualStrings("ABCDEF01", parts[2]);
    try std.testing.expectEqualStrings("23456789", parts[9]);
    try std.testing.expectEqualStrings("\\EFI\\Pizza\\ABCDEF01\\23456789\\ABCDEF01\\23456789\\ABCDEF01\\23456789\\ABCDEF01\\23456789\\maint.efi", try bootPath(a, id));
    try std.testing.expectError(error.InvalidDeviceIdentity, segments(a, "../escape"));
    try std.testing.expectEqualStrings("RECEIPT.BIN", filename(.receipt));
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), limit(.receipt));
}

test "receipt decode checks the same session and disk on both native ports" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, 4096 + 65536);
    defer a.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], "PZRCPT01");
    std.mem.writeInt(u32, bytes[8..12], 2, .little);
    std.mem.writeInt(u32, bytes[12..16], 4096, .little);
    @memset(bytes[16..48], 1);
    @memset(bytes[48..80], 2);
    @memcpy(bytes[4096..4098], "{}");
    @memcpy(bytes[80..112], &boot.digest("{}"));
    @memcpy(bytes[4064..4096], &boot.digest(bytes[0..4064]));
    try std.testing.expectError(error.CompletionReceiptIdentityMismatch, decode(a, .receipt, bytes, @splat(3), @splat(2)));
    try std.testing.expectError(error.CompletionReceiptIdentityMismatch, decode(a, .receipt, bytes, @splat(1), @splat(3)));
    const result = (try decode(a, .receipt, try a.dupe(u8, bytes), @splat(1), @splat(2))).?;
    defer a.free(result);
    try std.testing.expectEqualStrings("{}", result);
    const zero = try a.alloc(u8, 4096);
    @memset(zero, 0);
    try std.testing.expect((try decode(a, .lease, zero, @splat(1), @splat(2))) == null);
}
