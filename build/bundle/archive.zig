//! Standard GNU tar/cpio/gzip operate on Pizza's application overlay only.
const std = @import("std");
const utils = @import("utils");
const bundle = @import("bundle");
const files = @import("files.zig");
const release = @import("release.zig");

fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

pub fn layer(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, overlay: []const u8, output: []const u8) !void {
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, overlay, a);
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(a);
    defer walker.deinit();
    var names: std.array_list.Managed([]const u8) = .init(a);
    try names.append(".");
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory, .file => {},
            .sym_link => {
                var target: [std.fs.max_path_bytes]u8 = undefined;
                const count = try directory.readLink(io, entry.path, &target);
                if (std.fs.path.isAbsolute(target[0..count])) return error.EscapingSymlink;
                _ = try bundle.rooted(a, io, root, entry.path);
            },
            else => return error.InvalidApplicationFile,
        }
        try names.append(try a.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, names.items, {}, less);
    var input: std.array_list.Managed(u8) = .init(a);
    for (names.items) |name| {
        try directory.setTimestamps(io, name, .{ .follow_symlinks = false, .access_timestamp = .{ .new = .{ .nanoseconds = 0 } }, .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } } });
        try input.appendSlice(name);
        try input.append(0);
    }
    const list_path = try a.print("{s}.names", .{output});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = list_path, .data = input.items });
    defer std.Io.Dir.cwd().deleteFile(io, list_path) catch {};
    const list = try std.Io.Dir.cwd().openFile(io, list_path, .{});
    defer list.close(io);
    const archive = try std.Io.Dir.cwd().createFile(io, output, .{ .exclusive = true });
    defer archive.close(io);
    try redirect(io, env, .{ .argv = &.{ "cpio", "--create", "--format=newc", "--reproducible", "--owner=0:0", "--null", "--quiet" }, .cwd = .{ .path = root }, .stdin = .{ .file = list }, .stdout = .{ .file = archive } });
    try archive.sync(io);
}

fn redirect(io: std.Io, env: *std.process.Environ.Map, options: std.process.SpawnOptions) !void {
    var configured = options;
    configured.environ_map = env;
    var child = try std.process.spawn(io, configured);
    defer child.kill(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.CommandFailed;
}

pub fn appendFile(io: std.Io, source: []const u8, output: []const u8) !void {
    const input = try std.Io.Dir.cwd().openFile(io, source, .{});
    defer input.close(io);
    const destination = try std.Io.Dir.cwd().openFile(io, output, .{ .mode = .read_write });
    defer destination.close(io);
    var offset = (try destination.stat(io)).size;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = input.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        try destination.writePositionalAll(io, buffer[0..count], offset);
        offset += count;
    }
    try destination.sync(io);
}

pub fn image(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, root: []const u8, destination: []const u8) !void {
    _ = try @import("root.zig").verify(a, io, root);
    const lock = try release.readLock(a, io, try files.join(a, &.{ root, "release.json" }));
    _ = try release.verify(a, io, env, root, lock);
    const output = try files.Output.init(a, io, destination, false);
    defer output.deinit(io);
    if (utils.filesystem.pathIsWithin(root, output.target)) return error.ImageMustBeOutsideSource;
    const overlay = try files.join(a, &.{ output.temporary, "overlay" });
    try utils.process.runInherited(io, env, &.{ "cp", "-a", "--", try files.join(a, &.{ root, "overlay" }), overlay });
    const cpio = try files.join(a, &.{ output.temporary, "application.cpio" });
    try layer(a, io, env, overlay, cpio);
    const compressed_path = try files.join(a, &.{ output.temporary, "application.cpio.gz" });
    const compressed = try std.Io.Dir.cwd().createFile(io, compressed_path, .{ .exclusive = true });
    defer compressed.close(io);
    try redirect(io, env, .{ .argv = &.{ "gzip", "-n", "-c", cpio }, .stdin = .ignore, .stdout = .{ .file = compressed } });
    const combined = try files.join(a, &.{ output.temporary, "maint.img" });
    try std.Io.Dir.cwd().copyFile(try files.join(a, &.{ root, lock.asset }), .cwd(), combined, io, .{});
    try appendFile(io, compressed_path, combined);
    try output.publish(io, combined);
}

pub fn pack(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, source: []const u8, destination: []const u8) !void {
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, source, a);
    _ = try @import("root.zig").verify(a, io, root);
    const output = try files.Output.init(a, io, destination, false);
    defer output.deinit(io);
    if (utils.filesystem.pathIsWithin(root, output.target)) return error.BundleArchiveMustBeOutsideSource;
    const archive = try files.join(a, &.{ output.temporary, "bundle.tar.gz" });
    try utils.process.runInherited(io, env, &.{ "tar", "--sort=name", "--mtime=@0", "--owner=0", "--group=0", "--numeric-owner", "-czf", archive, "-C", root, "." });
    try output.publish(io, archive);
}
