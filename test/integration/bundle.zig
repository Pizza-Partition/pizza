const std = @import("std");
const bundle = @import("bundle");
const utils = @import("utils");

test "bundle paths reject traversal and symlinks escaping the staging directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try utils.filesystem.createTemporaryDirectory(a, io, "pizza-runtime-path-");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "file" }), .data = "fixture" });
    _ = try bundle.rooted(a, io, root, "file");
    try std.testing.expectError(error.UnsafePath, bundle.rooted(a, io, root, "../file"));
    try std.testing.expectError(error.UnsafePath, bundle.rooted(a, io, root, "/etc/passwd"));
    try std.Io.Dir.cwd().symLink(io, "/etc/passwd", try std.fs.path.join(a, &.{ root, "escape" }), .{});
    try std.testing.expectError(error.EscapingSymlink, bundle.rooted(a, io, root, "escape"));
}
