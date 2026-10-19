const std = @import("std");
const utils = @import("utils");
const clap = @import("clap");

const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--check  Check without changing files.
);

/// Formats repository Zig, frontend, JSON, documentation and C files using configured formatters.
/// Parses subcommand arguments; --check reports formatting drift without modifying source files.
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
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tools fmt [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    }
    const check = (parsed.args.check != 0);
    const prettier = std.Io.Dir.cwd().statFile(io, "ui/node_modules/prettier/bin/prettier.cjs", .{}) catch return error.RunZigBuildDeps;
    if (prettier.kind != .file)
        return error.RunZigBuildDeps;
    _ = try utils.process.findExecutable(allocator, io, environ, "clang-format");
    var command: std.array_list.Managed([]const u8) = .init(allocator);
    defer command.deinit();
    try command.appendSlice(&.{ environ.get("ZIG") orelse "zig", "fmt" });
    if (check) try command.append("--check");
    try command.appendSlice(&.{ "build.zig", "build.zig.zon", "build", "core", "tools", "test", "ui" });
    try utils.process.runInherited(io, environ, command.items);
    try utils.process.runInherited(
        io,
        environ,
        &.{
            (environ.get("NODE") orelse "node"),
            "ui/node_modules/prettier/bin/prettier.cjs",
            if (check) "--check" else "--write",
            "--ignore-path",
            ".prettierignore",
            "**/*.{json,js,mjs,ts,css,html,yaml,yml,md}",
            ".prettierrc.json",
        },
    );
    if (check)
        try utils.process.runInherited(
            io,
            environ,
            &.{
                "clang-format",
                "--dry-run",
                "--Werror",
                "test/matrix/abi_check.c",
            },
        )
    else
        try utils.process.runInherited(
            io,
            environ,
            &.{
                "clang-format",
                "-i",
                "test/matrix/abi_check.c",
            },
        );
}
