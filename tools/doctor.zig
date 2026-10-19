const std = @import("std");
const utils = @import("utils");
const clap = @import("clap");

const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--profile <str>  Dependency profile: build, qemu, image, kiosk or matrix.
    \\--wpe-api <str>  WPE API: auto, 2.0 or 1.1.
);

/// Checks system tools and applicable version requirements for the selected dependency profile.
/// Parses subcommand arguments and returns an error when required dependencies are unavailable.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
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
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tools doctor [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    }
    const profile = (parsed.args.profile orelse "build");
    const commands: []const []const u8 = if (std.mem.eql(u8, profile, "build")) &.{
        "zig",
        "node",
        "npm",
    } else if (std.mem.eql(u8, profile, "qemu")) &.{
        "qemu-system-x86_64",
        "qemu-img",
    } else if (std.mem.eql(u8, profile, "image")) &.{
        "zig",
        "dracut",
        "systemctl",
        "kexec",
        "modinfo",
        "modprobe",
        "zstd",
        "xz",
        "gzip",
    } else if (std.mem.eql(u8, profile, "kiosk")) &.{
        "pkg-config",
    } else if (std.mem.eql(u8, profile, "matrix")) &.{
        "qemu-system-x86_64",
        "qemu-img",
        "cloud-localds",
    } else return error.UnknownProfile;
    var failed = false;
    for (commands) |command| {
        var name = command;
        for ([_][2][]const u8{
            .{ "zig", "ZIG" },
            .{ "node", "NODE" },
            .{ "npm", "NPM" },
        }) |override| {
            if (std.mem.eql(u8, command, override[0])) {
                name = environ.get(override[1]) orelse command;
                break;
            }
        }
        const found = utils.process.findExecutable(allocator, io, environ, name) catch {
            failed = true;
            continue;
        };
        std.log.info("{s}: {s}", .{ command, found });
    }
    if (std.mem.eql(u8, profile, "build") and !failed) {
        const actual = std.mem.trim(
            u8,
            try utils.process.checkedOutput(
                allocator,
                io,
                environ,
                &.{
                    (environ.get("ZIG") orelse "zig"),
                    "version",
                },
            ),
            " \t\r\n",
        );
        if (!std.mem.eql(
            u8,
            actual,
            std.mem.trim(
                u8,
                try std.Io.Dir.cwd().readFileAlloc(
                    io,
                    ".zigversion",
                    allocator,
                    .limited(128 * 1024 * 1024),
                ),
                " \t\r\n",
            ),
        ))
            return error.IncompatibleZig;
        const node = std.mem.trim(
            u8,
            try utils.process.checkedOutput(
                allocator,
                io,
                environ,
                &.{
                    (environ.get("NODE") orelse "node"),
                    "--version",
                },
            ),
            " \t\r\n",
        );
        var parts = std.mem.splitScalar(
            u8,
            std.mem.trimStart(u8, node, "v"),
            '.',
        );
        if (try std.fmt.parseInt(u32, parts.next() orelse "", 10) < 22) {
            return error.IncompatibleNode;
        }
    }
    if (std.mem.eql(u8, profile, "kiosk") and !failed) {
        var api = (parsed.args.@"wpe-api" orelse "auto");
        if (std.mem.eql(u8, api, "auto")) {
            const output = try std.process.run(allocator, io, .{
                .argv = &.{ "pkg-config", "--exists", "wpe-webkit-2.0" },
                .environ_map = environ,
                .stdout_limit = .limited(32 * 1024 * 1024),
                .stderr_limit = .limited(32 * 1024 * 1024),
            });
            api = if (output.term == .exited and output.term.exited == 0) "2.0" else "1.1";
        }
        const libraries: []const []const u8 = if (std.mem.eql(u8, api, "2.0")) &.{
            "wpe-webkit-2.0",
            "wpe-platform-2.0",
            "wpe-platform-drm-2.0",
            "wpe-platform-headless-2.0",
        } else if (std.mem.eql(u8, api, "1.1")) &.{
            "wpe-webkit-1.1",
            "wpe-1.0",
            "wpebackend-fdo-1.0",
        } else return error.UnknownWpeApi;
        for (libraries) |library| std.log.info("{s}: {s}", .{
            library,
            std.mem.trim(
                u8,
                try utils.process.checkedOutput(
                    allocator,
                    io,
                    environ,
                    &.{ "pkg-config", "--modversion", library },
                ),
                " \t\r\n",
            ),
        });
        for ([_][]const u8{
            "glib-2.0",
            "gio-2.0",
            "egl",
            "gbm",
            "libdrm",
            "libinput",
            "fontconfig",
        }) |library| std.log.info("{s}: {s}", .{
            library,
            std.mem.trim(
                u8,
                try utils.process.checkedOutput(
                    allocator,
                    io,
                    environ,
                    &.{ "pkg-config", "--modversion", library },
                ),
                " \t\r\n",
            ),
        });
    }
    if (failed)
        return error.MissingSystemDependencies;
}
