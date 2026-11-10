//! Real libblockdev calls, exclusively against private temporary regular files.
//! This does not qualify kernel partition updates or replace VM acceptance.
const std = @import("std");
const libc = @import("libc");
const blockdev = @import("../core/platform/linux/blockdev.zig");
fn image(dir: std.Io.Dir, a: std.mem.Allocator) ![:0]const u8 {
    const file = try dir.createFile(std.testing.io, "disk.img", .{ .exclusive = true });
    try file.setLength(std.testing.io, 64 * 1024 * 1024);
    try std.testing.expectEqual(.file, (try file.stat(std.testing.io)).kind);
    file.close(std.testing.io);
    return dir.realPathFileAlloc(std.testing.io, "disk.img", a);
}
fn command(a: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(a, std.testing.io, .{ .argv = argv, .stdout_limit = .limited(65536), .stderr_limit = .limited(65536) });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}: {s}\n", .{ argv[0], result.stderr });
        return error.ImageVerificationCommandFailed;
    }
    return result.stdout;
}
fn field(bytes: []const u8, key: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == '=') return line[key.len + 1 ..];
    return error.MissingFilesystemField;
}
fn digest(path: []const u8) ![32]u8 {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .follow_symlinks = false });
    defer file.close(std.testing.io);
    if ((try file.stat(std.testing.io)).kind != .file) return error.RegularFixtureRequired;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    var at: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(std.testing.io, &buffer, at);
        if (n == 0) break;
        h.update(buffer[0..n]);
        at += n;
    }
    return h.finalResult();
}
test "system libblockdev formats and relabels an ext4 image; rejected writes change no byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try image(temp.dir, a);
    blockdev.perform(.{ .disk = path, .part = path, .kind = .format, .filesystem = "ext4", .label = "Pizza Test" }) catch {
        std.debug.print("libblockdev: {s}\n", .{blockdev.lastError()});
        return error.ImageFormatFailed;
    };
    const before = try command(a, &.{ "blkid", "-p", "-o", "export", path });
    try std.testing.expectEqualStrings("ext4", try field(before, "TYPE"));
    // blkid export escapes spaces; preserve the actual label passed to mkfs.
    try std.testing.expectEqualStrings("Pizza\\ Test", try field(before, "LABEL"));
    const original = try digest(path);
    try blockdev.preflightShrink(path, "ext4", 32 * 1024 * 1024, false);
    try std.testing.expectError(error.HostPreflightFailed, blockdev.preflightShrink(path, "ext4", 512, false));
    try std.testing.expectEqualSlices(u8, &original, &try digest(path));
    try std.testing.expectError(error.NativeOperationFailed, blockdev.perform(.{ .disk = path, .part = path, .kind = .format, .filesystem = "ext4", .label = "this label exceeds sixteen bytes", .mounted = false }));
    try std.testing.expectEqualSlices(u8, &original, &try digest(path));
    try std.testing.expectError(error.NativeOperationFailed, blockdev.perform(.{ .disk = path, .part = path, .kind = .format, .filesystem = "ext4", .label = "Mounted", .mounted = true }));
    try std.testing.expectEqualSlices(u8, &original, &try digest(path));
    try blockdev.perform(.{ .disk = path, .part = path, .kind = .label, .filesystem = "ext4", .label = "Renamed", .mounted = false });
    const after = try command(a, &.{ "blkid", "-p", "-o", "export", path });
    try std.testing.expectEqualStrings("Renamed", try field(after, "LABEL"));
    try std.testing.expectEqualStrings(try field(before, "UUID"), try field(after, "UUID"));
    _ = try command(a, &.{ "e2fsck", "-f", "-n", path });
}
test "a competing disk lease rejects formatting before any file byte changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try image(temp.dir, arena.allocator());
    const file = try temp.dir.openFile(std.testing.io, "disk.img", .{});
    defer file.close(std.testing.io);
    try std.testing.expectEqual(@as(c_int, 0), libc.flock(file.handle, libc.LOCK_EX | libc.LOCK_NB));
    defer _ = libc.flock(file.handle, libc.LOCK_UN);
    const original = try digest(path);
    try std.testing.expectError(error.NativeOperationFailed, blockdev.perform(.{ .disk = path, .part = path, .kind = .format, .filesystem = "ext4", .label = "Locked", .mounted = false }));
    try std.testing.expectEqualSlices(u8, &original, &try digest(path));
}
