//! Windows capability decisions are pure and testable without Windows or COM.
const std = @import("std");
const wire = @import("proto").wire;
pub const Encryption = @FieldType(wire.HostPartition, "encryption");

pub fn encryption(conversion_status: ?u64) Encryption {
    // Suspended protection does not mean decrypted. Only FullyDecrypted is safe.
    return if (conversion_status) |status| if (status == 0) .none else .encrypted else .unknown;
}

pub fn filesystem(name: []const u8) ?wire.FilesystemKind {
    if (std.ascii.eqlIgnoreCase(name, "NTFS")) return .ntfs;
    if (std.ascii.eqlIgnoreCase(name, "FAT32") or std.ascii.eqlIgnoreCase(name, "FAT")) return .vfat;
    if (std.ascii.eqlIgnoreCase(name, "exFAT")) return .exfat;
    return null;
}

pub fn canFs(fs: wire.FilesystemKind, op: wire.IntentKind) bool {
    return switch (op) {
        .resize => fs == .ntfs,
        .label, .format => fs == .ntfs or fs == .vfat or fs == .exfat,
        // Creation needs an exact GPT UUID compiler; movement needs maintenance.
        else => false,
    };
}

pub fn validLabel(fs: wire.FilesystemKind, label: []const u8) bool {
    const limit: usize = switch (fs) {
        .ntfs => 32,
        .vfat => 11,
        .exfat => 15,
        else => return false,
    };
    if (!std.unicode.utf8ValidateSlice(label)) return false;
    var count: usize = 0;
    var iter = std.unicode.Utf8View.initUnchecked(label).iterator();
    while (iter.nextCodepoint()) |cp| {
        if (cp < 32 or cp == 127 or (cp < 128 and std.mem.indexOfScalar(u8, "\\/:*?\"<>|", @intCast(cp)) != null)) return false;
        // FAT labels use OEM encoding and uppercase. Avoid silently changing a reviewed label.
        if (fs == .vfat and (cp > 126 or (cp >= 'a' and cp <= 'z'))) return false;
        if (fs == .vfat and std.mem.indexOfScalar(u8, "+,;=[]", @intCast(cp)) != null) return false;
        count += if (cp > 0xffff) @as(usize, 2) else 1;
    }
    return count <= limit and (label.len == 0 or label[label.len - 1] != ' ');
}

pub const State = struct {
    fs: ?wire.FilesystemKind = null,
    encrypted: Encryption = .unknown,
    protected: bool = true,
    read_only: bool = true,
    offline: bool = true,
    healthy: bool = false,
    simple: bool = false,

    pub fn writable(self: State) !void {
        if (self.encrypted == .encrypted) return error.bitlocker_unsupported;
        if (self.encrypted == .unknown) return error.encryption_state_unknown;
        if (self.protected) return error.protected_partition;
        if (!self.simple) return error.unsupported_volume_mapping;
        if (self.read_only or self.offline or !self.healthy) return error.volume_not_ready;
        if (self.fs == null) return error.windows_operation_unsupported;
    }
};

pub fn capabilities(a: std.mem.Allocator, state: State) ![]const wire.HostCapability {
    const reason: ?[]const u8 = if (state.writable()) |_| null else |err| @errorName(err);
    const kinds = [_]wire.IntentKind{ .resize, .format, .label, .delete, .move, .copy };
    const out = try a.alloc(wire.HostCapability, kinds.len);
    for (kinds, out) |op, *cap| {
        const allowed = reason == null and canFs(state.fs.?, op);
        cap.* = .{
            .operation = op,
            .backend = .host,
            .support = if (allowed) .available else .unavailable,
            .reason = if (allowed) "windows_storage_management" else reason orelse "windows_operation_unsupported",
            .grow = allowed and op == .resize,
            .shrink = allowed and op == .resize,
        };
    }
    return out;
}

test "encryption never treats suspended protection or an unreadable state as decrypted" {
    try std.testing.expectEqual(.none, encryption(0));
    for ([_]u64{ 1, 2, 3, 4, 5, 99 }) |v| try std.testing.expectEqual(.encrypted, encryption(v));
    try std.testing.expectEqual(.unknown, encryption(null));
}

test "only ready simple data volumes expose Windows writes" {
    const safe: State = .{ .fs = .ntfs, .encrypted = .none, .protected = false, .read_only = false, .offline = false, .healthy = true, .simple = true };
    try safe.writable();
    inline for (.{ "protected", "read_only", "offline" }) |field| {
        var bad = safe;
        @field(bad, field) = true;
        try std.testing.expectError(if (std.mem.eql(u8, field, "protected")) error.protected_partition else error.volume_not_ready, bad.writable());
    }
    inline for (.{ "healthy", "simple" }) |field| {
        var bad = safe;
        @field(bad, field) = false;
        try std.testing.expectError(if (std.mem.eql(u8, field, "simple")) error.unsupported_volume_mapping else error.volume_not_ready, bad.writable());
    }
    var bad = safe;
    bad.encrypted = .encrypted;
    try std.testing.expectError(error.bitlocker_unsupported, bad.writable());
    bad.encrypted = .unknown;
    try std.testing.expectError(error.encryption_state_unknown, bad.writable());
    bad = safe;
    bad.fs = null;
    try std.testing.expectError(error.windows_operation_unsupported, bad.writable());
    const missing_fs = try capabilities(std.testing.allocator, bad);
    defer std.testing.allocator.free(missing_fs);
    try std.testing.expectEqualStrings("windows_operation_unsupported", missing_fs[0].reason);
    var fat = safe;
    fat.fs = .vfat;
    const fat_caps = try capabilities(std.testing.allocator, fat);
    defer std.testing.allocator.free(fat_caps);
    try std.testing.expectEqualStrings("windows_operation_unsupported", fat_caps[0].reason);
    try std.testing.expectEqualStrings("windows_storage_management", fat_caps[1].reason);
    try std.testing.expect(!canFs(.vfat, .resize));
    try std.testing.expect(!canFs(.ntfs, .create));
}

test "labels count UTF-16 units and reject truncation and FAT normalization" {
    var utf8: [4]u8 = undefined;
    // Cover non-ASCII input, including supplementary UTF-16 code points,
    // without assigning a particular natural-language volume label.
    for ([_]u21{ 0x4e00, 0x1f600 }) |cp| {
        const n = try std.unicode.utf8Encode(cp, &utf8);
        try std.testing.expect(validLabel(.ntfs, utf8[0..n]));
    }
    try std.testing.expect(validLabel(.ntfs, ""));
    try std.testing.expect(!validLabel(.ntfs, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expect(!validLabel(.ntfs, "😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀"));
    try std.testing.expect(!validLabel(.ntfs, "bad/name"));
    try std.testing.expect(!validLabel(.ntfs, "x\x00y"));
    try std.testing.expect(!validLabel(.vfat, "lowercase"));
    try std.testing.expect(validLabel(.vfat, "DATA"));
    try std.testing.expect(!validLabel(.vfat, "DATA+COPY"));
}
