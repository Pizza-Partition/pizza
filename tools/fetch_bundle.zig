//! Native bundle download and build-tool bootstrap entry points.
const std = @import("std");
const clap = @import("clap");
const bundle_build = @import("bundle_build");
const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--destination <str>  New output directory (required).
    \\--lock <str>  Runtime release lock (default: config/bundle/release.json).
);

pub fn run(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, bootstrap: bool, argv: []const []const u8) !void {
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var parsed = try clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{ .allocator = a });
    defer parsed.deinit();
    if (parsed.args.help != 0) return clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    const destination = parsed.args.destination orelse return error.MissingDestination;
    if (bootstrap) {
        if (parsed.args.lock != null) return error.UnexpectedArgument;
        try bundle_build.bootstrapPatchelf(a, io, env, destination);
    } else {
        try bundle_build.release.fetch(a, io, env, parsed.args.lock orelse bundle_build.release.lock_path, destination);
    }
}
