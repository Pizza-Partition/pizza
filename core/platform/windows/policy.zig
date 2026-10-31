//! Windows capability decisions are pure and testable without Windows or COM.
const std = @import("std");
const w = @import("proto").wire;
pub const Encryption = @FieldType(w.HostPartition, "encryption");
pub fn encryption(conversion_status: ?u64) Encryption {
    // Suspended protection does not mean decrypted. Only FullyDecrypted is safe.
    return if (conversion_status) |status| if (status == 0) .none else .encrypted else .unknown;
}
pub fn filesystem(name: []const u8) ?w.FilesystemKind {
    if (std.ascii.eqlIgnoreCase(name, "NTFS")) return .ntfs;
    if (std.ascii.eqlIgnoreCase(name, "FAT32") or std.ascii.eqlIgnoreCase(name, "FAT")) return .vfat;
    if (std.ascii.eqlIgnoreCase(name, "exFAT")) return .exfat;
    return null;
}
pub fn canFs(fs: w.FilesystemKind, op: w.IntentKind) bool {
    return switch (op) {
        .resize => fs == .ntfs,
        .label, .format => fs == .ntfs or fs == .vfat or fs == .exfat,
        // Creation needs an exact GPT UUID compiler; movement needs maintenance.
        else => false,
    };
}
pub fn validLabel(fs: w.FilesystemKind, label: []const u8) bool {
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
    fs: ?w.FilesystemKind = null,
    encrypted: Encryption = .unknown,
    protected: bool = true,
    read_only: bool = true,
    offline: bool = true,
    healthy: bool = false,
    simple: bool = false,
    pub fn writable(self: State) bool {
        return self.fs != null and self.encrypted == .none and !self.protected and !self.read_only and !self.offline and self.healthy and self.simple;
    }
    pub fn reason(self: State) []const u8 {
        if (self.encrypted == .encrypted) return "bitlocker_unsupported";
        if (self.encrypted == .unknown) return "encryption_state_unknown";
        if (self.protected) return "protected_partition";
        if (!self.simple) return "unsupported_volume_mapping";
        if (self.read_only or self.offline or !self.healthy) return "volume_not_ready";
        return "windows_operation_unsupported";
    }
};
pub fn capabilities(a: std.mem.Allocator, state: State) ![]const w.HostCapability {
    const kinds = [_]w.IntentKind{ .resize, .format, .label, .delete, .move, .copy };
    const out = try a.alloc(w.HostCapability, kinds.len);
    for (kinds, out) |op, *cap| {
        const allowed = state.writable() and canFs(state.fs.?, op);
        cap.* = .{ .operation = op, .backend = .host, .support = if (allowed) .available else .unavailable, .reason = if (allowed) "windows_storage_management" else state.reason(), .grow = allowed and op == .resize, .shrink = allowed and op == .resize };
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
    try std.testing.expect(safe.writable());
    inline for (.{ "protected", "read_only", "offline" }) |field| {
        var bad = safe;
        @field(bad, field) = true;
        try std.testing.expect(!bad.writable());
    }
    inline for (.{ "healthy", "simple" }) |field| {
        var bad = safe;
        @field(bad, field) = false;
        try std.testing.expect(!bad.writable());
    }
    var bad = safe;
    bad.encrypted = .encrypted;
    try std.testing.expect(!bad.writable());
    bad.encrypted = .unknown;
    try std.testing.expect(!bad.writable());
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
