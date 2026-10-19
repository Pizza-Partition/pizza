//! Explicit staging and orderly transition; report never mutates storage.
const std = @import("std");
const clap = @import("clap");
const proto = @import("proto");
const kexec = @import("kexec.zig");
const Command = enum { help, transition };
const Operation = enum { build, transition, report };
const parsers = .{ .str = clap.parsers.string, .command = clap.parsers.enumeration(Command), .operation = clap.parsers.enumeration(Operation) };
const params = clap.parseParamsComptime(
    \\-h, --help  Display help and exit.
    \\-V, --version  Display version.
    \\--kernel <str>  Matching bzImage for staging.
    \\--initrd <str>  Prepared maintenance image with .pizza.json metadata.
    \\--plan <str>  Validated simulated plan JSON for the new session.
    \\--journal-device <str>  Independent ext4 block device, already mounted for staging.
    \\--journal-home <str>  Existing private root-owned directory on journal device.
    \\--workspace <str>  Private RAM staging directory (default: /run/pizza/transition).
    \\--journal <str>  Read-only report input (default: /var/lib/pizza/journal.bin).
    \\--no-ui  Execute in console mode after transition.
    \\--test-poweroff  VM only: power off after the console test session ends.
    \\<command>  help or transition.
    \\<operation>  build, transition or report.
);
pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    var diagnostic: clap.Diagnostic = .{};
    var parsed = clap.parse(clap.Help, &params, parsers, init.minimal.args, .{ .allocator = a, .diagnostic = &diagnostic }) catch |err| {
        std.log.err("Command line: {t}; argument: {s}", .{ err, diagnostic.arg });
        return 1;
    };
    defer parsed.deinit();
    if (parsed.args.version != 0) {
        try std.Io.File.stdout().writeStreamingAll(init.io, try a.print("pizza 0.1.0 (protocol v{d})\n", .{proto.api_version}));
        return 0;
    }
    if (parsed.args.help != 0 or (parsed.positionals[0] orelse .help) == .help) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Usage: pizza transition <build|transition|report>\n");
        try clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{});
        return 0;
    }
    const operation = parsed.positionals[1] orelse {
        std.log.err("Missing transition operation", .{});
        return 1;
    };
    const options: kexec.Options = .{
        .workspace = parsed.args.workspace orelse "/run/pizza/transition",
        .kernel = parsed.args.kernel,
        .initrd = parsed.args.initrd,
        .plan = parsed.args.plan,
        .journal_device = parsed.args.@"journal-device",
        .journal_home = parsed.args.@"journal-home",
        .no_ui = parsed.args.@"no-ui" != 0,
        .test_poweroff = parsed.args.@"test-poweroff" != 0,
    };
    dispatch(a, init.io, init.environ_map, operation, options, parsed.args.journal) catch |err| {
        std.log.err("transition {t}: {t}", .{ operation, err });
        return 1;
    };
    return 0;
}
fn dispatch(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, operation: Operation, options: kexec.Options, journal: ?[]const u8) !void {
    switch (operation) {
        .build => {
            _ = try kexec.staged(a, io, options);
        },
        .transition => try kexec.transition(a, io, env, options.workspace),
        .report => try @import("report.zig").run(a, io, journal orelse if (options.journal_home) |home| try std.fs.path.join(a, &.{ home, "journal.bin" }) else "/var/lib/pizza/journal.bin"),
    }
}
