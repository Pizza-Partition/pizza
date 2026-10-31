//! Host checks; pure business checks also run through domain.zig.
const std = @import("std");
const proto = @import("proto");
test {
    _ = @import("../core/boot/maintenance.zig");
    _ = @import("domain.zig");
    _ = @import("../core/desktop/http.zig");
    if (comptime @import("builtin").os.tag == .linux) {
        _ = @import("../core/platform/linux/session/client.zig");
        _ = @import("../core/platform/linux/session.zig");
        _ = @import("../core/platform/linux/session/store.zig");
        _ = @import("../core/platform/linux/session/transport.zig");
        _ = @import("../core/platform/linux/blockdev.zig");
        _ = @import("../core/platform/linux/maintenance.zig");
        _ = @import("../core/platform/linux/maintenance_store.zig");
        _ = @import("../core/platform/linux/esp.zig");
        _ = @import("../core/platform/linux/efivars.zig");
    } else {
        _ = @import("windows.zig");
    }
}
test "Linux inventory uses the single current wire contract" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const s = try @import("../core/platform/linux/inventory.zig").query(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@import("proto").API_VERSION, s.version);
    try std.testing.expectEqual(@as(usize, 64), s.snapshot_id.len);
}

test "fetched protocol package matches its export manifest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const evidence = @import("protocol_package");
    const Manifest = struct { wire_version: u16, source: []const u8, files: []const struct { name: []const u8, sha256: []const u8 } };
    const manifest = try std.json.parseFromSliceLeaky(Manifest, a, evidence.manifest, .{});
    try std.testing.expectEqual(proto.API_VERSION, manifest.wire_version);
    try std.testing.expectEqualStrings("pizza-maint", manifest.source);
    try std.testing.expect(manifest.files.len != 0);
    try std.testing.expectEqual(manifest.files.len, evidence.names.len);
    try std.testing.expectEqual(manifest.files.len, evidence.hashes.len);
    for (manifest.files, 0..) |file, i| {
        for (manifest.files[0..i]) |other| try std.testing.expect(!std.mem.eql(u8, file.name, other.name));
        try std.testing.expectEqualStrings(file.name, evidence.names[i]);
        try std.testing.expectEqualStrings(file.sha256, evidence.hashes[i]);
    }
}
