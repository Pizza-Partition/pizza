const std = @import("std");
pub const cases = @import("cases.zig");
pub const Allocator = std.mem.Allocator;
pub fn hostBootId(a: Allocator, io: std.Io) ![]const u8 {
    // procfs reports size zero; readFileAlloc's positional regular-file path
    // would silently return an empty identifier and make the check vacuous.
    const file = try std.Io.Dir.cwd().openFile(io, "/proc/sys/kernel/random/boot_id", .{});
    defer file.close(io);
    var bytes: [64]u8 = undefined;
    var length: usize = 0;
    while (length < bytes.len) {
        const n = file.readStreaming(io, &.{bytes[length..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        length += n;
    }
    const id = std.mem.trim(u8, bytes[0..length], "\r\n");
    if (id.len != 36) return error.InvalidHostBootId;
    for (id, 0..) |ch, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (ch != '-') return error.InvalidHostBootId;
        } else if (!std.ascii.isHex(ch)) return error.InvalidHostBootId;
    }
    return a.dupe(u8, id);
}

test "host boot identifier is read from size-zero procfs" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const id = try hostBootId(std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(id);
    try std.testing.expectEqual(@as(usize, 36), id.len);
}
pub fn hash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
pub fn runAt(a: Allocator, io: std.Io, env: ?*const std.process.Environ.Map, cwd: std.process.Child.Cwd, argv: []const []const u8, input: ?[]const u8, seconds: i64) !std.process.RunResult {
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = cwd, .environ_map = env, .stdin = if (input != null) .pipe else .ignore, .stdout = .pipe, .stderr = .pipe, .create_no_window = true });
    defer child.kill(io);
    if (input) |bytes| {
        try child.stdin.?.writeStreamingAll(io, bytes);
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const deadline = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(seconds), .clock = .awake } }).toDeadline(io);
    while (reader.fill(4096, deadline)) |_| {
        for (0..2) |i| if (reader.reader(i).buffered().len > 16 * 1024 * 1024) return error.OutputTooLarge;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    return .{ .term = try child.wait(io), .stdout = try reader.toOwnedSlice(0), .stderr = try reader.toOwnedSlice(1) };
}
pub fn check(result: std.process.RunResult) ![]const u8 {
    if (!result.term.success()) {
        std.debug.print("child failed: {f}\n{s}\n{s}\n", .{ result.term, result.stderr, result.stdout });
        return error.CommandFailed;
    }
    return std.mem.trim(u8, result.stdout, " \r\n\t");
}
