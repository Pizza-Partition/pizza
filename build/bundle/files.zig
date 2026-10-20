//! Atomic outputs shared by the bundle build steps.
const std = @import("std");
const utils = @import("utils");

pub const Output = struct {
    target: []const u8,
    temporary: []const u8,

    pub fn init(a: std.mem.Allocator, io: std.Io, destination: []const u8, directory: bool) !Output {
        const target = try utils.filesystem.resolveOutputPath(a, io, try std.process.currentPathAlloc(io, a), destination);
        if (directory) {
            if (std.Io.Dir.cwd().openDir(io, target, .{ .iterate = true })) |dir| {
                var opened = dir;
                defer opened.close(io);
                var iterator = opened.iterate();
                if (try iterator.next(io) != null) return error.OutputAlreadyExists;
                try std.Io.Dir.cwd().deleteDir(io, target); // Zig precreates empty generated directories.
            } else |err| switch (err) {
                error.FileNotFound => {},
                error.NotDir => return error.OutputAlreadyExists,
                else => return err,
            }
        } else {
            if (std.Io.Dir.cwd().access(io, target, .{})) |_| return error.OutputAlreadyExists else |err| if (err != error.FileNotFound) return err;
        }
        const parent = std.fs.path.dirname(target) orelse return error.InvalidOutput;
        try std.Io.Dir.cwd().createDirPath(io, parent);
        var random: [16]u8 = undefined;
        std.Io.random(io, &random);
        const temporary = try std.fs.path.join(a, &.{ parent, try a.print(".pizza-build-{s}", .{std.fmt.bytesToHex(random, .lower)}) });
        try std.Io.Dir.cwd().createDir(io, temporary, .default_dir);
        return .{ .target = target, .temporary = temporary };
    }

    pub fn deinit(self: Output, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.temporary) catch {};
    }
};
