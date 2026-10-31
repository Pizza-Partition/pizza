const std = @import("std");
const clap = @import("clap");
pub const Mode = enum { ui, serve, inventory, plan, validate, request, @"privileged-exec", @"complete-session" };
pub const Options = struct { mode: Mode = .ui, port: u16 = 4173, help: bool = false, parent_pid: ?u32 = null };
const PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>  ui (default), serve, inventory, plan, validate, request, privileged-exec, complete-session.
);
const COMMAND_PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
);
const SERVE_PARAMS = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<port>     Loopback port, 1024–65535 (default: 4173).
);
const PRIVILEGED_PARAMS = clap.parseParamsComptime(
    \\-h, --help       Display this help and exit.
    \\--parent <pid>   Internal Windows authorization parent process.
);

fn parsePort(value: []const u8) !u16 {
    const port = clap.parsers.int(u16, 10)(value) catch return error.InvalidPort;
    if (port < 1024) return error.InvalidPort;
    return port;
}

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Options {
    var iter: clap.args.SliceIterator = .{ .args = args };
    var parsed = clap.parseEx(clap.Help, &PARAMS, .{ .command = clap.parsers.enumeration(Mode) }, &iter, .{
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| switch (err) {
        error.NameNotPartOfEnum => return error.UnknownCommand,
        else => return err,
    };
    defer parsed.deinit();
    const mode = parsed.positionals[0] orelse .ui;
    var options: Options = .{ .mode = mode, .help = parsed.args.help != 0 };
    if (comptime @import("builtin").os.tag == .windows) {
        if (mode == .@"privileged-exec") {
            var privileged = clap.parseEx(clap.Help, &PRIVILEGED_PARAMS, .{ .pid = clap.parsers.int(u32, 10) }, &iter, .{ .allocator = allocator }) catch |err| switch (err) {
                error.InvalidArgument => return error.UnexpectedArgument,
                else => return err,
            };
            defer privileged.deinit();
            options.parent_pid = privileged.args.parent;
            if (options.parent_pid == 0) return error.InvalidParentProcess;
            options.help = options.help or privileged.args.help != 0;
            return options;
        }
    }
    if (mode == .serve) {
        var serve = clap.parseEx(clap.Help, &SERVE_PARAMS, .{ .port = parsePort }, &iter, .{
            .allocator = allocator,
            .terminating_positional = 0,
        }) catch |err| switch (err) {
            error.InvalidArgument => return error.UnexpectedArgument,
            else => return err,
        };
        defer serve.deinit();
        options.port = serve.positionals[0] orelse 4173;
        options.help = options.help or serve.args.help != 0;
    }
    var command = clap.parseEx(clap.Help, &COMMAND_PARAMS, .{}, &iter, .{ .allocator = allocator }) catch |err| switch (err) {
        error.InvalidArgument => return error.UnexpectedArgument,
        else => return err,
    };
    defer command.deinit();
    options.help = options.help or command.args.help != 0;
    return options;
}

pub fn help(io: std.Io, mode: Mode) !void {
    if (mode == .serve) {
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza serve [port] [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &SERVE_PARAMS, .{});
    }
    try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza [command] [options]\n");
    try clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
}
test "browser service is explicit, loopback-port only, and accepts no helper arguments" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(.ui, (try parse(a, &.{})).mode);
    try std.testing.expectEqual(@as(u16, 4173), (try parse(a, &.{"serve"})).port);
    try std.testing.expectEqual(@as(u16, 4180), (try parse(a, &.{ "serve", "4180" })).port);
    try std.testing.expectError(error.InvalidPort, parse(a, &.{ "serve", "0" }));
    try std.testing.expectError(error.InvalidPort, parse(a, &.{ "serve", "0.0.0.0:4173" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(a, &.{ "privileged-exec", "unexpected-helper-path" }));
    try std.testing.expectError(error.UnknownCommand, parse(a, &.{"privileged_exec"}));
}
test "clap preserves commands and port limits and rejects extra arguments" {
    const a = std.testing.allocator;
    inline for (std.meta.tags(Mode)) |mode|
        try std.testing.expectEqual(mode, (try parse(a, &.{@tagName(mode)})).mode);
    try std.testing.expectEqual(@as(u16, 1024), (try parse(a, &.{ "serve", "1024" })).port);
    try std.testing.expectEqual(@as(u16, 65535), (try parse(a, &.{ "serve", "65535" })).port);
    try std.testing.expectError(error.InvalidPort, parse(a, &.{ "serve", "1023" }));
    try std.testing.expectError(error.InvalidPort, parse(a, &.{ "serve", "65536" }));
    try std.testing.expectError(error.InvalidPort, parse(a, &.{ "serve", "0x1050" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(a, &.{ "serve", "4173", "4180" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(a, &.{ "inventory", "4173" }));
    try std.testing.expectError(error.UnknownCommand, parse(a, &.{"unknown"}));
}
test "clap accepts help and rejects unknown options" {
    const a = std.testing.allocator;
    try std.testing.expect((try parse(a, &.{"--help"})).help);
    try std.testing.expect((try parse(a, &.{"-h"})).help);
    const serve = try parse(a, &.{ "serve", "--help" });
    try std.testing.expectEqual(.serve, serve.mode);
    try std.testing.expect(serve.help);
    try std.testing.expect((try parse(a, &.{ "serve", "4173", "--help" })).help);
    try std.testing.expect((try parse(a, &.{ "inventory", "--help" })).help);
    try std.testing.expectError(error.InvalidArgument, parse(a, &.{"--unknown"}));
}
test "authorization parent is parsed only for the Windows privileged command" {
    const a = std.testing.allocator;
    if (comptime @import("builtin").os.tag == .windows) {
        const options = try parse(a, &.{ "privileged-exec", "--parent", "1234" });
        try std.testing.expectEqual(@as(?u32, 1234), options.parent_pid);
        try std.testing.expectError(error.InvalidParentProcess, parse(a, &.{ "privileged-exec", "--parent", "0" }));
    } else {
        try std.testing.expectError(error.UnexpectedArgument, parse(a, &.{ "privileged-exec", "--parent", "1234" }));
    }
    try std.testing.expectError(error.UnexpectedArgument, parse(a, &.{ "inventory", "--parent", "1234" }));
}
