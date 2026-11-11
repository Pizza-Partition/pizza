const std = @import("std");
const proto = @import("proto");
const wire = proto.wire;

/// Standard GPT types in their canonical and on-disk representations.
/// Adapters compare these values; they do not maintain independent copies.
pub const Gpt = struct {
    pub const ESP_GUID = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b";
    pub const BASIC_DATA_GUID = "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7";
    pub const LINUX_DATA_GUID = "0fc63daf-8483-4772-8e79-3d69d8477de4";
    pub const ESP = std.fmt.bytesToHex(parseGuid(ESP_GUID) catch unreachable, .lower);
    pub const BASIC_DATA = std.fmt.bytesToHex(parseGuid(BASIC_DATA_GUID) catch unreachable, .lower);
    pub const LINUX_DATA = std.fmt.bytesToHex(parseGuid(LINUX_DATA_GUID) catch unreachable, .lower);

    pub fn filesystemType(fs: wire.FilesystemKind) []const u8 {
        return switch (fs) {
            .ntfs, .exfat, .vfat, .udf => &BASIC_DATA,
            else => &LINUX_DATA,
        };
    }
};

/// Linux sysfs exposes SCSI VPD page 0x83 NAA/EUI identifiers in this form.
/// Windows obtains the same bytes via StorageDeviceIdProperty. No device path,
/// provider-generated serial or mutable GPT field participates in this identity.
pub fn diskFromWwid(wwid: []const u8) ![32]u8 {
    const prefix: usize = if (std.mem.startsWith(u8, wwid, "naa.") or std.mem.startsWith(u8, wwid, "eui."))
        4
    else
        return error.NonPortableDeviceIdentity;
    const bytes = wwid[prefix..];
    if (bytes.len != 16 and bytes.len != 24 and bytes.len != 32) return error.NonPortableDeviceIdentity;
    var canonical: [36]u8 = undefined;
    @memcpy(canonical[0..prefix], wwid[0..prefix]);
    var any: u8 = 0;
    for (bytes, 0..) |ch, i| {
        if (!std.ascii.isHex(ch)) return error.NonPortableDeviceIdentity;
        canonical[prefix + i] = std.ascii.toLower(ch);
        any |= if (ch != '0') @as(u8, 1) else 0;
    }
    if (any == 0) return error.NonPortableDeviceIdentity;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("pizza-physical-identity-v1\x00wwid\x00");
    hash.update(canonical[0..wwid.len]);
    const raw = hash.finalResult();
    hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&raw);
    hash.update("disk");
    return hash.finalResult();
}

/// New UUIDs use the GPT on-disk byte order, matching the shared storage identity.
pub fn guid(text: []const u8) ![16]u8 {
    if (text.len != 32) return error.InvalidGuid;
    for (text) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) return error.InvalidGuid;
    var bytes: [16]u8 = undefined;
    var any: u8 = 0;
    for (&bytes, 0..) |*b, i| {
        b.* = std.fmt.parseInt(u8, text[2 * i ..][0..2], 16) catch return error.InvalidGuid;
        any |= b.*;
    }
    if (any == 0) return error.InvalidGuid;
    return bytes;
}

pub fn partition(a: std.mem.Allocator, disk: []const u8, uuid: []const u8) ![]const u8 {
    const d = try proto.hexDigest(disk);
    const u = try guid(uuid);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("pizza-partition-identity-v2");
    hash.update(&d);
    hash.update(&u);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return a.dupe(u8, &std.fmt.bytesToHex(result, .lower));
}

/// Bind planning to geometry and identities, excluding changing usage counters.
pub const fingerprint = @import("proto").inventory_fingerprint.fingerprint;

fn swap(bytes: [16]u8) [16]u8 {
    return .{ bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15] };
}
pub fn canonicalGuid(a: std.mem.Allocator, bytes_text: []const u8) ![]const u8 {
    const hex = std.fmt.bytesToHex(swap(try guid(bytes_text)), .lower);
    return a.print("{{{s}-{s}-{s}-{s}-{s}}}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}

pub fn parseGuid(text: []const u8) ![16]u8 {
    const value = if (text.len == 38 and text[0] == '{' and text[37] == '}') text[1..37] else text;
    if (value.len != 36) return error.InvalidGuid;
    var hex: [32]u8 = undefined;
    var index: usize = 0;
    for (value, 0..) |ch, offset| {
        if (offset == 8 or offset == 13 or offset == 18 or offset == 23) {
            if (ch != '-') return error.InvalidGuid;
        } else {
            hex[index] = ch;
            index += 1;
        }
    }
    return swap(try guid(&hex));
}

test "provider GUIDs round-trip through GPT byte order and reject query injection" {
    const a = std.testing.allocator;
    const uuid = "00112233-4455-6677-8899-aabbccddeeff";
    const bytes = try parseGuid(uuid);
    try std.testing.expectEqualStrings("33221100554477668899aabbccddeeff", &std.fmt.bytesToHex(bytes, .lower));
    const canonical_text = try canonicalGuid(a, &std.fmt.bytesToHex(bytes, .lower));
    defer a.free(canonical_text);
    try std.testing.expectEqualStrings("{" ++ uuid ++ "}", canonical_text);
    try std.testing.expectEqual(bytes, try parseGuid(canonical_text));
    try std.testing.expectError(error.InvalidGuid, parseGuid("00112233'4455-6677-8899-aabbccddeeff"));
    try std.testing.expectError(error.InvalidGuid, parseGuid("00000000-0000-0000-0000-000000000000"));
}

test "portable VPD identity matches the Linux physical backend and ignores hexadecimal case" {
    const wwid = "naa.6001405abcde0123";
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("pizza-physical-identity-v1\x00");
    hash.update("wwid\x00");
    hash.update(wwid);
    const raw = hash.finalResult();
    hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&raw);
    hash.update("disk");
    const expected = hash.finalResult();
    try std.testing.expectEqual(expected, try diskFromWwid(wwid));
    try std.testing.expectEqual(expected, try diskFromWwid("naa.6001405ABCDE0123"));
    try std.testing.expectError(error.NonPortableDeviceIdentity, diskFromWwid("eui.0000000000000000"));
    try std.testing.expectError(error.NonPortableDeviceIdentity, diskFromWwid("QEMU disk 1"));
    try std.testing.expectError(error.NonPortableDeviceIdentity, diskFromWwid("naa.6001405abcdef012?"));
}
