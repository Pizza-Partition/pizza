const std = @import("std");
const utils = @import("utils");
const clap = @import("clap");

const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--destination <str>  Toolchain output directory outside the checkout.
);

/// Downloads and installs the pinned Zig toolchain outside the checkout after checking its SHA-256.
/// Parses subcommand arguments and verifies the extracted compiler version.
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
        try std.Io.File.stdout().writeStreamingAll(
            io,
            "Usage: pizza-tools bootstrap-zig [options]\n",
        );
        return clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    }
    const destination = try utils.filesystem.resolveOutputPath(
        allocator,
        io,
        checkout_root,
        (parsed.args.destination orelse "/tmp/pizza-toolchains"),
    );
    if (utils.filesystem.pathIsWithin(checkout_root, destination))
        return error.ToolchainMustBeOutsideCheckout;
    const config = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        try std.Io.Dir.cwd().readFileAlloc(
            io,
            "config/toolchain.json",
            allocator,
            .limited(128 * 1024 * 1024),
        ),
        .{ .allocate = .alloc_always },
    );
    const pin = std.mem.trim(
        u8,
        try std.Io.Dir.cwd().readFileAlloc(
            io,
            ".zigversion",
            allocator,
            .limited(128 * 1024 * 1024),
        ),
        " \t\r\n",
    );
    if (!std.mem.eql(u8, (switch ((switch (config) {
        .object => |object| object.get("version") orelse return error.MissingField,
        else => return error.ExpectedObject,
    })) {
        .string => |text| text,
        else => return error.ExpectedString,
    }), pin))
        return error.ToolchainLockMismatch;
    const item = (switch (config) {
        .object => |object| object.get("x86_64-linux") orelse return error.MissingField,
        else => return error.ExpectedObject,
    });
    const url = (switch ((switch (item) {
        .object => |object| object.get("url") orelse return error.MissingField,
        else => return error.ExpectedObject,
    })) {
        .string => |text| text,
        else => return error.ExpectedString,
    });
    const filename = std.fs.path.basename(url);
    if (!std.mem.endsWith(u8, filename, ".tar.xz"))
        return error.InvalidToolchainArchive;
    const directory = try std.fs.path.join(
        allocator,
        &.{
            destination,
            filename[0 .. filename.len - 7],
        },
    );
    const binary = try std.fs.path.join(allocator, &.{ directory, "zig" });
    try std.Io.Dir.cwd().createDirPath(io, destination);
    if (if (std.Io.Dir.cwd().statFile(io, binary, .{})) |stat| stat.kind != .file else |_| true) {
        const archive = try std.fs.path.join(allocator, &.{ destination, filename });
        if (if (std.Io.Dir.cwd().statFile(io, archive, .{})) |stat| stat.kind != .file else |_| true)
            try utils.process.runInherited(
                io,
                environ,
                &.{
                    "curl",
                    "--fail",
                    "--location",
                    "--max-time",
                    "60",
                    "--output",
                    archive,
                    url,
                },
            );
        if (!std.mem.eql(
            u8,
            try utils.filesystem.hashFileSha256(allocator, io, archive),
            (switch ((switch (item) {
                .object => |object| object.get("sha256") orelse return error.MissingField,
                else => return error.ExpectedObject,
            })) {
                .string => |text| text,
                else => return error.ExpectedString,
            }),
        ))
            return error.ToolchainArchiveHashMismatch;
        var random: [16]u8 = undefined;
        std.Io.random(io, &random);
        const staging = try std.fs.path.join(allocator, &.{ destination, try allocator.print(".pizza-zig-unpack-{s}", .{std.fmt.bytesToHex(random, .lower)}) });
        try std.Io.Dir.cwd().createDir(io, staging, .fromMode(0o700));
        defer std.Io.Dir.cwd().deleteTree(io, staging) catch {};
        const expected_root = filename[0 .. filename.len - 7];
        try utils.archive.extract(allocator, io, archive, staging, .xz, expected_root);
        try std.Io.Dir.cwd().renamePreserve(try std.fs.path.join(allocator, &.{ staging, expected_root }), .cwd(), directory, io);
    }
    if (!std.mem.eql(
        u8,
        std.mem.trim(
            u8,
            try utils.process.checkedOutput(allocator, io, environ, &.{ binary, "version" }),
            " \t\r\n",
        ),
        pin,
    ))
        return error.InstalledToolchainVersionMismatch;
    std.log.info("Toolchain ready: {s}", .{directory});
}
