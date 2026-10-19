const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    mode: u32,
    data: []const u8 = "",
    device_major: u32 = 0,
    device_minor: u32 = 0,
};

fn newc(
    allocator: std.mem.Allocator,
    entries: []const Entry,
) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;
    for (0..entries.len + 1) |index| {
        const entry: Entry = if (index == entries.len) .{
            .name = "TRAILER!!!",
            .mode = 0,
        } else entries[index];
        const fields = [_]u32{
            @intCast(index + 1),
            entry.mode,
            0,
            0,
            1,
            0,
            @intCast(entry.data.len),
            0,
            0,
            entry.device_major,
            entry.device_minor,
            @intCast(entry.name.len + 1),
            0,
        };
        try writer.writeAll("070701");
        for (fields) |value| try writer.print("{x:0>8}", .{value});
        try writer.writeAll(entry.name);
        try writer.writeByte(0);
        while (output.written().len % 4 != 0) try writer.writeByte(0);
        try writer.writeAll(entry.data);
        while (output.written().len % 4 != 0) try writer.writeByte(0);
    }
    return output.toOwnedSlice();
}

pub fn archive(
    allocator: std.mem.Allocator,
    entries: []const Entry,
) ![]const u8 {
    var output: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    const buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
    var compression = try std.compress.flate.Compress.init(
        &output.writer,
        buffer,
        .gzip,
        .default,
    );
    try compression.writer.writeAll(try newc(allocator, entries));
    try compression.finish();
    return output.toOwnedSlice();
}

/// Returns an allocator-owned deterministic gzip/newc archive containing dev/console (5:1).
/// This archive supplies the console device only; it contains no init executable.
pub fn console(allocator: std.mem.Allocator) ![]const u8 {
    return archive(
        allocator,
        &.{
            .{ .name = "dev", .mode = 0o040755 },
            .{
                .name = "dev/console",
                .mode = 0o020600,
                .device_major = 5,
                .device_minor = 1,
            },
        },
    );
}

/// Writes a gzip/newc initramfs containing the supplied binary as /init and dev/console.
/// Overwrites the output and creates parents; the caller must validate that the binary is static.
pub fn staticInit(
    allocator: std.mem.Allocator,
    io: std.Io,
    binary: []const u8,
    output: []const u8,
) !void {
    if (std.fs.path.dirname(output)) |parent|
        try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output,
        .data = try archive(
            allocator,
            &.{
                .{
                    .name = "init",
                    .mode = 0o100755,
                    .data = try std.Io.Dir.cwd().readFileAlloc(
                        io,
                        binary,
                        allocator,
                        .limited(128 * 1024 * 1024),
                    ),
                },
                .{ .name = "dev", .mode = 0o040755 },
                .{
                    .name = "dev/console",
                    .mode = 0o020600,
                    .device_major = 5,
                    .device_minor = 1,
                },
            },
        ),
    });
}

test "newc and gzip are deterministic and encode the console device" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entries = &.{
        Entry{
            .name = "init",
            .mode = 0o100755,
            .data = "example",
        },
        Entry{
            .name = "dev/console",
            .mode = 0o020600,
            .device_major = 5,
            .device_minor = 1,
        },
    };
    const raw = try newc(allocator, entries);
    const name_index = std.mem.indexOf(u8, raw, "dev/console\x00") orelse {
        return error.MissingConsole;
    };
    const index = name_index - 110;
    try std.testing.expectEqualStrings(
        "0000000500000001",
        raw[index + 78 .. index + 94],
    );
    try std.testing.expect(
        std.mem.indexOf(u8, raw, "TRAILER!!!\x00") != null,
    );
    const compressed = try archive(allocator, entries);
    try std.testing.expectEqualSlices(
        u8,
        compressed,
        try archive(allocator, entries),
    );
    var input: std.Io.Reader = .fixed(compressed);
    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompression: std.compress.flate.Decompress = .init(&input, .gzip, &buffer);
    try std.testing.expectEqualSlices(
        u8,
        raw,
        try decompression.reader.allocRemaining(allocator, .unlimited),
    );
}
