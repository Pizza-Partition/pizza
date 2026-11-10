//! Read-only GPT entry mapping. OS partition ordinals are not GPT array indexes.
const std = @import("std");
pub const Table = struct { offset: u64, bytes: usize, count: u32, stride: u32, checksum: u32, sector: u32, capacity: u64 };
pub fn table(header: []u8, sector: u32, capacity: u64) !Table {
    if (sector < 512 or sector > 4096 or !std.math.isPowerOfTwo(sector) or header.len != sector or capacity / sector < 3) return error.InvalidGpt;
    if (!std.mem.eql(u8, header[0..8], "EFI PART") or std.mem.readInt(u32, header[8..12], .little) != 0x10000) return error.InvalidGpt;
    const size = std.mem.readInt(u32, header[12..16], .little);
    if (size < 92 or size > sector or std.mem.readInt(u64, header[24..32], .little) != 1) return error.InvalidGpt;
    const checksum = std.mem.readInt(u32, header[16..20], .little);
    @memset(header[16..20], 0);
    const actual = std.hash.Crc32.hash(header[0..size]);
    std.mem.writeInt(u32, header[16..20], checksum, .little);
    if (actual != checksum) return error.InvalidGpt;
    const lba = std.mem.readInt(u64, header[72..80], .little);
    const count = std.mem.readInt(u32, header[80..84], .little);
    const stride = std.mem.readInt(u32, header[84..88], .little);
    if (count == 0 or count > 4096 or stride < 128 or stride > 4096 or stride % 128 != 0 or lba < 2 or lba >= capacity / sector) return error.InvalidGpt;
    const bytes: usize = @as(usize, count) * stride;
    const offset = lba * sector;
    if (bytes > capacity - offset) return error.InvalidGpt;
    return .{ .offset = offset, .bytes = bytes, .count = count, .stride = stride, .checksum = std.mem.readInt(u32, header[88..92], .little), .sector = sector, .capacity = capacity };
}
pub fn slot(bytes: []const u8, info: Table, uuid: []const u8, offset: u64, length: u64) !u32 {
    if (uuid.len != 16 or std.mem.allEqual(u8, uuid, 0) or bytes.len < info.bytes or std.hash.Crc32.hash(bytes[0..info.bytes]) != info.checksum) return error.InvalidGpt;
    var found: ?u32 = null;
    for (0..info.count) |i| {
        const entry = bytes[i * info.stride ..][0..128];
        if (std.mem.allEqual(u8, entry[0..16], 0) or !std.mem.eql(u8, entry[16..32], uuid)) continue;
        const first = std.mem.readInt(u64, entry[32..40], .little);
        const last = std.mem.readInt(u64, entry[40..48], .little);
        if (found != null or first > last or last >= info.capacity / info.sector or first * info.sector != offset or (last - first + 1) * info.sector != length) return error.WindowsPartitionMappingChanged;
        found = @intCast(i);
    }
    return found orelse error.WindowsPartitionMappingChanged;
}
test "GPT slot preserves holes and refuses corrupt or duplicate identities" {
    var bytes: [512]u8 = @splat(0);
    const uuid: [16]u8 = @splat(7);
    @memset(bytes[256..272], 1);
    @memcpy(bytes[272..288], &uuid);
    std.mem.writeInt(u64, bytes[288..296], 20, .little);
    std.mem.writeInt(u64, bytes[296..304], 29, .little);
    var info: Table = .{ .offset = 1024, .bytes = bytes.len, .count = 4, .stride = 128, .checksum = std.hash.Crc32.hash(&bytes), .sector = 512, .capacity = 1024 * 1024 };
    try std.testing.expectEqual(@as(u32, 2), try slot(&bytes, info, &uuid, 20 * 512, 10 * 512));
    bytes[0] = 1;
    try std.testing.expectError(error.InvalidGpt, slot(&bytes, info, &uuid, 20 * 512, 10 * 512));
    @memcpy(bytes[0..128], bytes[256..384]);
    info.checksum = std.hash.Crc32.hash(&bytes);
    try std.testing.expectError(error.WindowsPartitionMappingChanged, slot(&bytes, info, &uuid, 20 * 512, 10 * 512));
}

test "GPT headers require a valid checksum and bounded entry array" {
    var header: [512]u8 = @splat(0);
    @memcpy(header[0..8], "EFI PART");
    std.mem.writeInt(u32, header[8..12], 0x10000, .little);
    std.mem.writeInt(u32, header[12..16], 92, .little);
    std.mem.writeInt(u64, header[24..32], 1, .little);
    std.mem.writeInt(u64, header[72..80], 2, .little);
    std.mem.writeInt(u32, header[80..84], 128, .little);
    std.mem.writeInt(u32, header[84..88], 128, .little);
    std.mem.writeInt(u32, header[16..20], std.hash.Crc32.hash(header[0..92]), .little);
    try std.testing.expectEqual(@as(usize, 16384), (try table(&header, 512, 1024 * 1024)).bytes);
    try std.testing.expectError(error.InvalidGpt, table(&header, 512, 4096));
    header[88] ^= 1;
    try std.testing.expectError(error.InvalidGpt, table(&header, 512, 1024 * 1024));
}
