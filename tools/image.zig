const std = @import("std");
const clap = @import("clap");

const initramfs = @import("initramfs");
const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--bundle <str>  Local bundle directory (required).
    \\--output <str>  Initramfs output path (required).
    \\--kernel-version <str>  Kernel release (default: the bundled 7.2.11 kernel).
    \\--dry-run  Print the layer assembly command without creating the image.
);

/// Parses command-line options and delegates image creation to the initramfs module.
/// Prints the validated layer assembly command for --dry-run.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    checkout_root: []const u8,
    argv: []const []const u8,
) !void {
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var diagnostic: clap.Diagnostic = .{};
    var parsed = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
        .diagnostic = &diagnostic,
    }) catch |err| {
        std.log.err("Command line: {t}; argument: {s}", .{ err, diagnostic.arg });
        return err;
    };
    defer parsed.deinit();
    if (parsed.args.help != 0) {
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tools image [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    }
    const command = try initramfs.build(allocator, io, environ, checkout_root, .{
        .bundle = parsed.args.bundle orelse return error.MissingBundle,
        .output = parsed.args.output orelse return error.MissingOutput,
        .kernel_version = parsed.args.@"kernel-version",
        .dry_run = parsed.args.@"dry-run" != 0,
    });
    if (parsed.args.@"dry-run" != 0)
        try std.Io.File.stdout().writeStreamingAll(
            io,
            try std.json.Stringify.valueAlloc(
                allocator,
                command,
                .{ .whitespace = .indent_2 },
            ),
        );
}
