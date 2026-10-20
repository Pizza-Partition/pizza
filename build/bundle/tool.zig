//! Install the official, checksum-pinned patchelf build tool.
const std = @import("std");
const utils = @import("utils");
const files = @import("files.zig");
const release = @import("release.zig");

pub fn bootstrap(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, destination: []const u8) !void {
    const lock = try std.json.parseFromSliceLeaky(struct { version: []const u8, url: []const u8, sha256: []const u8 }, a, try std.Io.Dir.cwd().readFileAlloc(io, "config/patchelf.json", a, .limited(1024 * 1024)), .{ .ignore_unknown_fields = true });
    const output = try files.Output.init(a, io, destination, true);
    defer output.deinit(io);
    const archive = try std.fs.path.join(a, &.{ output.temporary, "tool.tar.gz" });
    try utils.process.runInherited(io, env, &.{ "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3", "--output", archive, lock.url });
    try release.verifyDigest(a, io, archive, lock.sha256);
    try utils.archive.extract(a, io, archive, output.temporary, .gzip, null);
    try std.Io.Dir.cwd().deleteFile(io, archive);
    const version = try utils.process.checkedOutput(a, io, env, &.{ try std.fs.path.join(a, &.{ output.temporary, "bin/patchelf" }), "--version" });
    if (!std.mem.eql(u8, std.mem.trim(u8, version, " \r\n\t"), try a.print("patchelf {s}", .{lock.version}))) return error.PatchelfVersionMismatch;
    try std.Io.Dir.cwd().renamePreserve(output.temporary, .cwd(), output.target, io);
}
