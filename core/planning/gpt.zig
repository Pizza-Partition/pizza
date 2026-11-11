//! Read-only GPT entry mapping. OS partition ordinals are not GPT array indexes.
const std = @import("std");
pub const Table = struct { offset_bytes: u64, entries_bytes: usize, entry_count: u32, entry_stride_bytes: u32, checksum: u32, logical_sector_bytes: u32, capacity_bytes: u64 };
pub fn table(header: []u8, logical_sector_bytes: u32, capacity_bytes: u64) !Table {
    if (logical_sector_bytes < 512 or logical_sector_bytes > 4096 or !std.math.isPowerOfTwo(logical_sector_bytes) or header.len != logical_sector_bytes or capacity_bytes / logical_sector_bytes < 3) return error.InvalidGpt;
    if (!std.mem.eql(u8, header[0..8], "EFI PART") or std.mem.readInt(u32, header[8..12], .little) != 0x10000) return error.InvalidGpt;
    const size = std.mem.readInt(u32, header[12..16], .little);
    if (size < 92 or size > logical_sector_bytes or std.mem.readInt(u64, header[24..32], .little) != 1) return error.InvalidGpt;
    const checksum = std.mem.readInt(u32, header[16..20], .little);
    @memset(header[16..20], 0);
    const actual = std.hash.Crc32.hash(header[0..size]);
    std.mem.writeInt(u32, header[16..20], checksum, .little);
    if (actual != checksum) return error.InvalidGpt;
    const lba = std.mem.readInt(u64, header[72..80], .little);
    const entry_count = std.mem.readInt(u32, header[80..84], .little);
    const entry_stride_bytes = std.mem.readInt(u32, header[84..88], .little);
    if (entry_count == 0 or entry_count > 4096 or entry_stride_bytes < 128 or entry_stride_bytes > 4096 or entry_stride_bytes % 128 != 0 or lba < 2 or lba >= capacity_bytes / logical_sector_bytes) return error.InvalidGpt;
    const entries_bytes: usize = @as(usize, entry_count) * entry_stride_bytes;
    const offset_bytes = lba * logical_sector_bytes;
    if (entries_bytes > capacity_bytes - offset_bytes) return error.InvalidGpt;
    return .{ .offset_bytes = offset_bytes, .entries_bytes = entries_bytes, .entry_count = entry_count, .entry_stride_bytes = entry_stride_bytes, .checksum = std.mem.readInt(u32, header[88..92], .little), .logical_sector_bytes = logical_sector_bytes, .capacity_bytes = capacity_bytes };
}
pub fn entryIndex(entries_bytes: []const u8, info: Table, uuid: []const u8, offset_bytes: u64, length_bytes: u64) !u32 {
    if (uuid.len != 16 or std.mem.allEqual(u8, uuid, 0) or entries_bytes.len < info.entries_bytes or std.hash.Crc32.hash(entries_bytes[0..info.entries_bytes]) != info.checksum) return error.InvalidGpt;
    var found: ?u32 = null;
    for (0..info.entry_count) |i| {
        const entry = entries_bytes[i * info.entry_stride_bytes ..][0..128];
        if (std.mem.allEqual(u8, entry[0..16], 0) or !std.mem.eql(u8, entry[16..32], uuid)) continue;
        const first = std.mem.readInt(u64, entry[32..40], .little);
        const last = std.mem.readInt(u64, entry[40..48], .little);
        if (found != null or first > last or last >= info.capacity_bytes / info.logical_sector_bytes or first * info.logical_sector_bytes != offset_bytes or (last - first + 1) * info.logical_sector_bytes != length_bytes) return error.WindowsPartitionMappingChanged;
        found = @intCast(i);
    }
    return found orelse error.WindowsPartitionMappingChanged;
}
test "GPT slot preserves holes and refuses corrupt or duplicate identities" {
    var entries_bytes: [512]u8 = @splat(0);
    const uuid: [16]u8 = @splat(7);
    @memset(entries_bytes[256..272], 1);
    @memcpy(entries_bytes[272..288], &uuid);
    std.mem.writeInt(u64, entries_bytes[288..296], 20, .little);
    std.mem.writeInt(u64, entries_bytes[296..304], 29, .little);
    var info: Table = .{ .offset_bytes = 1024, .entries_bytes = entries_bytes.len, .entry_count = 4, .entry_stride_bytes = 128, .checksum = std.hash.Crc32.hash(&entries_bytes), .logical_sector_bytes = 512, .capacity_bytes = 1024 * 1024 };
    try std.testing.expectEqual(@as(u32, 2), try entryIndex(&entries_bytes, info, &uuid, 20 * 512, 10 * 512));
    entries_bytes[0] = 1;
    try std.testing.expectError(error.InvalidGpt, entryIndex(&entries_bytes, info, &uuid, 20 * 512, 10 * 512));
    @memcpy(entries_bytes[0..128], entries_bytes[256..384]);
    info.checksum = std.hash.Crc32.hash(&entries_bytes);
    try std.testing.expectError(error.WindowsPartitionMappingChanged, entryIndex(&entries_bytes, info, &uuid, 20 * 512, 10 * 512));
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
    try std.testing.expectEqual(@as(usize, 16384), (try table(&header, 512, 1024 * 1024)).entries_bytes);
    try std.testing.expectError(error.InvalidGpt, table(&header, 512, 4096));
    header[88] ^= 1;
    try std.testing.expectError(error.InvalidGpt, table(&header, 512, 1024 * 1024));
}
