//! RAM-only staged file hashes. Durable state lives on journal media.
const std = @import("std");
const session = @import("session");
pub const Stage = struct {
    request: session.Request,
    kernel_sha256: []const u8,
    initrd_sha256: []const u8,
    journal_home: []const u8,
    journal_device: []const u8,
    cmdline: []const u8,
};

pub fn read(a: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) !Stage {
    try session.storage.trustedFile(io, directory, "stage.json");
    const result = try std.json.parseFromSliceLeaky(Stage, a, try directory.readFileAlloc(io, "stage.json", a, .limited(32 * 1024)), .{});
    try result.request.validate();
    if (!session.hex(result.kernel_sha256, 64) or !session.hex(result.initrd_sha256, 64) or result.cmdline.len == 0 or result.cmdline.len > 2047 or std.mem.indexOfScalar(u8, result.cmdline, 0) != null) return error.InvalidStage;
    return result;
}
