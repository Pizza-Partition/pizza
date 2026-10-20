//! Native gzip/XZ and TAR extraction for checksum-authenticated build tools.
const std = @import("std");
const filesystem = @import("filesystem.zig");
pub const Compression = enum { gzip, xz };

/// `source` must be authenticated before this function is called. In this pinned
/// Zig revision XZ data checksums are not implemented; the caller's SHA-256 pin
/// authenticates the complete compressed stream. Decode to a file so TAR never
/// calls this XZ reader's unimplemented discard operation.
pub fn extract(a: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8, compression: Compression, required_root: ?[]const u8) !void {
    const temporary = try filesystem.createTemporaryDirectory(a, io, "pizza-unpack-");
    defer std.Io.Dir.cwd().deleteTree(io, temporary) catch {};
    const tar = try std.fs.path.join(a, &.{ temporary, "archive.tar" });
    try decompress(a, io, source, tar, compression);
    const file = try std.Io.Dir.cwd().openFile(io, tar, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try extractTar(a, io, &reader.interface, destination, required_root);
}

pub fn decompress(a: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8, compression: Compression) !void {
    const file = try std.Io.Dir.cwd().openFile(io, source, .{});
    defer file.close(io);
    const output = try std.Io.Dir.cwd().createFile(io, destination, .{ .exclusive = true });
    defer output.close(io);
    var input_buffer: [64 * 1024]u8 = undefined;
    var output_buffer: [64 * 1024]u8 = undefined;
    var input = file.reader(io, &input_buffer);
    var writer = output.writer(io, &output_buffer);
    switch (compression) {
        .gzip => {
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var decoder: std.compress.flate.Decompress = .init(&input.interface, .gzip, &window);
            const result = try transfer(&decoder.reader, &writer.interface);
            if (decoder.container_metadata.gzip.crc != result.crc or decoder.container_metadata.gzip.count != @as(u32, @truncate(result.count))) return error.GzipChecksumMismatch;
        },
        .xz => {
            var decoder = try std.compress.xz.Decompress.init(&input.interface, a, &.{});
            defer decoder.deinit();
            _ = try transfer(&decoder.reader, &writer.interface);
        },
    }
    if (input.interface.peekByte()) |_| return error.TrailingCompressedData else |err| if (err != error.EndOfStream) return err;
    try writer.interface.flush();
    try output.sync(io);
}
fn transfer(reader: *std.Io.Reader, writer: *std.Io.Writer) !struct { crc: u32, count: u64 } {
    var crc = std.hash.crc.@"CRC-32/ISO-HDLC".init();
    var count: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&buffer);
        if (n == 0) break;
        crc.update(buffer[0..n]);
        count += n;
        try writer.writeAll(buffer[0..n]);
    }
    return .{ .crc = crc.final(), .count = count };
}

fn path(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0 or std.fs.path.isAbsolute(raw) or std.mem.indexOfScalar(u8, raw, 0) != null) return error.UnsafeArchivePath;
    var parts: std.array_list.Managed([]const u8) = .init(a);
    var iterator = std.mem.tokenizeScalar(u8, raw, '/');
    while (iterator.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.UnsafeArchivePath;
        if (!std.mem.eql(u8, part, ".")) try parts.append(part);
    }
    return std.mem.join(a, "/", parts.items);
}
fn directory(io: std.Io, root: std.Io.Dir, name: []const u8) !void {
    const stat = root.statFile(io, name, .{ .follow_symlinks = false }) catch |err| {
        if (err != error.FileNotFound) return err;
        return root.createDir(io, name, .fromMode(0o755));
    };
    if (stat.kind != .directory) return error.ArchiveSymlinkParent;
}

/// Use std.tar for parsing; enforce confinement and reject symlink ancestors
/// before creating files. Extraction never overwrites existing files or links.
pub fn extractTar(a: std.mem.Allocator, io: std.Io, reader: *std.Io.Reader, destination: []const u8, required_root: ?[]const u8) !void {
    var root = try std.Io.Dir.cwd().openDir(io, destination, .{});
    defer root.close(io);
    const absolute_root = try std.Io.Dir.cwd().realPathFileAlloc(io, destination, a);
    const link_root = if (required_root) |required| try std.fs.path.join(a, &.{ absolute_root, required }) else absolute_root;
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var iterator: std.tar.Iterator = .init(reader, .{ .file_name_buffer = &name_buffer, .link_name_buffer = &link_buffer });
    while (try iterator.next()) |entry| {
        const name = try path(a, entry.name);
        if (name.len == 0) {
            if (entry.kind != .directory) return error.UnsafeArchivePath;
            continue;
        }
        if (required_root) |required| {
            const end = std.mem.indexOfScalar(u8, name, '/') orelse name.len;
            if (!std.mem.eql(u8, name[0..end], required)) return error.UnsafeArchivePath;
        }
        for (name, 0..) |byte, i| if (byte == '/') try directory(io, root, name[0..i]);
        switch (entry.kind) {
            .directory => {
                if (entry.size != 0) return error.InvalidArchiveDirectory;
                try directory(io, root, name);
            },
            .file => {
                const output = try root.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(entry.mode & 0o777) });
                defer output.close(io);
                var buffer: [64 * 1024]u8 = undefined;
                var writer = output.writer(io, &buffer);
                try iterator.streamRemaining(entry, &writer.interface);
                try writer.interface.flush();
                try output.setPermissions(io, .fromMode(entry.mode & 0o777));
            },
            .sym_link => {
                if (entry.size != 0 or std.fs.path.isAbsolute(entry.link_name) or entry.link_name.len == 0) return error.UnsafeArchiveLink;
                const resolved = try std.fs.path.resolve(a, &.{ absolute_root, std.fs.path.dirname(name) orelse ".", entry.link_name });
                if (!filesystem.pathIsWithin(link_root, resolved)) return error.UnsafeArchiveLink;
                try root.symLink(io, entry.link_name, name, .{});
            },
        }
    }
}
