const std = @import("std");
const utils = @import("utils");
const clap = @import("clap");

const Command = enum {
    help,
    proto,
    fmt,
    doctor,
    @"verify-bundle",
    @"prepare-bundle",
    @"pack-bundle",
    image,
    @"bootstrap-zig",
    clean,
};
const parsers = .{ .command = clap.parsers.enumeration(Command) };
const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>  proto, fmt, doctor, verify-bundle, prepare-bundle, pack-bundle, image, bootstrap-zig, clean.
);

/// Dispatches engineering commands and translates argument or command failures into exit status 1.
pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    const io = init.io;
    const environ = init.environ_map;
    const checkout_root = try std.process.currentPathAlloc(io, allocator);
    var iter: clap.args.SliceIterator = .{ .args = argv[1..] };
    var diagnostic: clap.Diagnostic = .{};
    var parsed = clap.parseEx(clap.Help, &params, parsers, &iter, .{
        .allocator = allocator,
        .diagnostic = &diagnostic,
        .terminating_positional = 0,
    }) catch |err| {
        std.log.err("Command line: {t}; argument: {s}", .{ err, diagnostic.arg });
        return 1;
    };
    defer parsed.deinit();
    if (parsed.args.help != 0 or parsed.positionals[0] == null) {
        try help(io);
        return 0;
    }
    const command = parsed.positionals[0].?;
    dispatch(allocator, io, environ, checkout_root, command, iter.args[iter.index..]) catch |err| {
        std.log.err("{t}: {t}", .{ command, err });
        return 1;
    };
    return 0;
}

fn help(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tools <command> [options]\n");
    try clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    try std.Io.File.stdout().writeStreamingAll(io, "Use zig build tools -- <command> [options].\n");
}

fn dispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    checkout_root: []const u8,
    command: Command,
    argv: []const []const u8,
) !void {
    switch (command) {
        .help => {
            if (argv.len != 0)
                return error.UnexpectedArgument;
            return help(io);
        },
        .proto => try @import("protocol.zig").generate(allocator, io, environ, argv),
        .fmt => try @import("format.zig").run(allocator, io, environ, argv),
        .doctor => try @import("doctor.zig").run(allocator, io, environ, argv),
        .@"verify-bundle" => try @import("verify_bundle.zig").run(allocator, io, environ, argv),
        .@"prepare-bundle" => try @import(
            "prepare.zig",
        ).run(
            allocator,
            io,
            environ,
            checkout_root,
            argv,
        ),
        .@"pack-bundle" => try @import(
            "package_bundle.zig",
        ).run(
            allocator,
            io,
            environ,
            checkout_root,
            argv,
        ),
        .image => try @import("image.zig").run(allocator, io, environ, checkout_root, argv),
        .@"bootstrap-zig" => try @import(
            "bootstrap.zig",
        ).run(
            allocator,
            io,
            environ,
            checkout_root,
            argv,
        ),
        .clean => try clean(allocator, io, argv),
    }
}

fn clean(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const clean_params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
    );
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var diagnostic: clap.Diagnostic = .{};
    var parsed = clap.parseEx(clap.Help, &clean_params, clap.parsers.default, &iter, .{
        .allocator = allocator,
        .diagnostic = &diagnostic,
    }) catch |err| {
        std.log.err("Command line: {t}; argument: {s}", .{ err, diagnostic.arg });
        return err;
    };
    defer parsed.deinit();
    if (parsed.args.help != 0) {
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tools clean [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &clean_params, .{});
    }
    for ([_][]const u8{ ".zig-cache", "zig-out", "ui/execution/gui/dist" }) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        try std.Io.Dir.cwd().deleteTree(io, path);
    }
}
