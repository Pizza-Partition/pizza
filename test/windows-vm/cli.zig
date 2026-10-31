//! Argument schemas shared by the host tools and the staged Windows guest.
const std = @import("std");
const clap = @import("clap");

pub const Artifacts = struct {
    pub const USAGE = "zig build build-windows-vm-artifacts -Dheadless=true -- [options]";
    pub const PARAMS = clap.parseParamsComptime(
        \\-h, --help                  Display this help and exit.
        \\--out <str>                 Output root (default: .zig-cache/windows-e2e).
        \\--root <str>                Pizza checkout (default: this build's checkout).
        \\--zig <str>                 Zig executable (default: this build's Zig).
        \\--timeout <seconds>         Per-command deadline, 1–21600 (default: 3600).
    );
    const PARSERS = .{ .str = clap.parsers.string, .seconds = artifactTimeout };
    pub fn parse(a: std.mem.Allocator, args: []const []const u8) !clap.ResultEx(clap.Help, &PARAMS, PARSERS) {
        return parseArgs(&PARAMS, PARSERS, true, a, args);
    }
};

pub const Fetch = struct {
    pub const USAGE = "zig build fetch-windows-image -Dheadless=true -- [options]";
    pub const PARAMS = clap.parseParamsComptime(
        \\-h, --help         Display this help and exit.
        \\--config <str>     Image configuration (default: test/windows-vm/images.json).
        \\--image <str>      Image ID (default: configured default_image).
        \\--out <str>        Cache directory (default: configured cache_dir).
        \\--verify-only     Verify the cached image without downloading.
    );
    const PARSERS = .{ .str = clap.parsers.string };
    pub fn parse(a: std.mem.Allocator, args: []const []const u8) !clap.ResultEx(clap.Help, &PARAMS, PARSERS) {
        return parseArgs(&PARAMS, PARSERS, false, a, args);
    }
};

pub const Runner = struct {
    pub const USAGE = "zig build test-windows-vm -Dheadless=true -Dvm-libvirt=PREFIX -- [options]";
    pub const Native = enum { run, skip };
    pub const PARAMS = clap.parseParamsComptime(
        \\-h, --help           Display this help and exit.
        \\--base <str>         Required: directory with the frozen Windows/OVMF baseline.
        \\--stage <str>        Required: directory with the staged Windows binaries.
        \\--out <str>          Required: new output directory; its parent must exist.
        \\--user <str>         Windows SAC username (default: perdixky).
        \\--timeout <seconds>  Wait deadline, 1–3600 (default: 600).
        \\--native <native>    Native test selection: run or skip (default: run).
        \\--cases <str>        Comma-separated cases (default: all five cases).
        \\--transport <str>    sac or agent (default: baseline manifest, otherwise sac).
    );
    const PARSERS = .{ .str = clap.parsers.string, .seconds = runnerTimeout, .native = parseNative };
    pub const Options = @FieldType(clap.ResultEx(clap.Help, &PARAMS, PARSERS), "args");
    pub fn parse(a: std.mem.Allocator, args: []const []const u8) !clap.ResultEx(clap.Help, &PARAMS, PARSERS) {
        var result = try parseArgs(&PARAMS, PARSERS, true, a, args);
        errdefer result.deinit();
        if (result.args.help == 0) {
            if (result.args.base == null) return error.BaseRequired;
            if (result.args.stage == null) return error.StageRequired;
            if (result.args.out == null) return error.OutputRequired;
        }
        return result;
    }
};

pub const Guest = struct {
    pub const USAGE = "windows-vm-guest [options] <action> <work> <serial> <wwn> <case>";
    pub const Action = enum { install, collect, probe, servicing, freeze, restart, setup, native, plan, prepare, reboot, verify, shutdown };
    pub const PARAMS = clap.parseParamsComptime(
        \\-h, --help   Display this help and exit.
        \\<action>    install, collect, probe, servicing, freeze, restart, setup, native, plan, prepare, reboot, verify, shutdown.
        \\<work>      Working directory.
        \\<serial>    Target disk serial.
        \\<wwn>       Target disk WWN.
        \\<case>      Test case.
    );
    const PARSERS = .{ .action = parseAction, .work = clap.parsers.string, .serial = clap.parsers.string, .wwn = clap.parsers.string, .case = clap.parsers.string };
    pub fn parse(a: std.mem.Allocator, args: []const []const u8) !clap.ResultEx(clap.Help, &PARAMS, PARSERS) {
        var result = try parseArgs(&PARAMS, PARSERS, false, a, args);
        errdefer result.deinit();
        if (result.args.help == 0) {
            inline for (result.positionals) |value| {
                if (value == null) return error.ExpectedActionWorkSerialWwnCase;
            }
        }
        return result;
    }
};

pub fn help(io: std.Io, comptime Command: type) !void {
    try std.Io.File.stdout().writeStreamingAll(io, "Usage: " ++ Command.USAGE ++ "\n");
    try clap.helpToFile(io, .stdout(), clap.Help, &Command.PARAMS, .{});
}

fn artifactTimeout(value: []const u8) !i64 {
    const seconds = try clap.parsers.int(i64, 10)(value);
    if (seconds < 1 or seconds > 21600) return error.InvalidTimeout;
    return seconds;
}

fn runnerTimeout(value: []const u8) !u32 {
    const seconds = try clap.parsers.int(u32, 10)(value);
    if (seconds == 0 or seconds > 3600) return error.InvalidTimeout;
    return seconds;
}

fn parseNative(value: []const u8) !Runner.Native {
    return clap.parsers.enumeration(Runner.Native)(value) catch return error.InvalidNativeSelection;
}

fn parseAction(value: []const u8) !Guest.Action {
    return clap.parsers.enumeration(Guest.Action)(value) catch return error.UnknownAction;
}

fn parseArgs(comptime PARAMS: []const clap.Param(clap.Help), comptime PARSERS: anytype, comptime UNIQUE: bool, a: std.mem.Allocator, args: []const []const u8) !clap.ResultEx(clap.Help, PARAMS, PARSERS) {
    // parseEx keeps the last single value. Preserve the host tools' rejection of
    // duplicate options, and reject extra guest positionals instead of replacing
    // the last one. Let clap tokenize options, including --name=value and --.
    var iter: clap.args.SliceIterator = .{ .args = args };
    var stream: clap.streaming.Clap(clap.Help, clap.args.SliceIterator) = .{ .params = PARAMS, .iter = &iter };
    var seen: [PARAMS.len]bool = @splat(false);
    var positionals: usize = 0;
    const MAX_POSITIONALS = comptime blk: {
        var count: usize = 0;
        for (PARAMS) |param| {
            if (param.names.longest().kind == .positional) count += 1;
        }
        break :blk count;
    };
    while (try stream.next()) |arg| {
        if (arg.param.names.longest().kind == .positional) {
            positionals += 1;
            if (positionals > MAX_POSITIONALS) return error.UnexpectedArgument;
        } else if (UNIQUE and arg.param.takes_value == .one) {
            for (PARAMS, 0..) |*param, index| {
                if (arg.param != param) continue;
                if (seen[index]) return error.UnknownOrDuplicateOption;
                seen[index] = true;
            }
        }
    }
    iter = .{ .args = args };
    return clap.parseEx(clap.Help, PARAMS, PARSERS, &iter, .{ .allocator = a });
}

test "artifact options preserve defaults and parse paths and deadlines" {
    const a = std.testing.allocator;
    var defaults = try Artifacts.parse(a, &.{});
    defer defaults.deinit();
    try std.testing.expect(defaults.args.root == null and defaults.args.timeout == null);
    var parsed = try Artifacts.parse(a, &.{ "--root", "checkout path", "--out", "output", "--zig", "zig", "--timeout", "21600" });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("checkout path", parsed.args.root.?);
    try std.testing.expectEqual(@as(?i64, 21600), parsed.args.timeout);
    try std.testing.expectError(error.InvalidTimeout, Artifacts.parse(a, &.{ "--timeout", "0" }));
    try std.testing.expectError(error.InvalidTimeout, Artifacts.parse(a, &.{ "--timeout", "21601" }));
    try std.testing.expectError(error.InvalidCharacter, Artifacts.parse(a, &.{ "--timeout", "invalid" }));
}

test "fetch selection and verify-only retain last-value semantics" {
    const a = std.testing.allocator;
    var defaults = try Fetch.parse(a, &.{});
    defer defaults.deinit();
    try std.testing.expect(defaults.args.config == null and defaults.args.image == null and defaults.args.out == null);
    try std.testing.expectEqual(@as(u8, 0), defaults.args.@"verify-only");
    var parsed = try Fetch.parse(a, &.{ "--config", "images.json", "--image=first", "--image", "second", "--out", "cache path", "--verify-only" });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("images.json", parsed.args.config.?);
    try std.testing.expectEqualStrings("second", parsed.args.image.?);
    try std.testing.expectEqualStrings("cache path", parsed.args.out.?);
    try std.testing.expect(parsed.args.@"verify-only" != 0);
    try std.testing.expectError(error.DoesntTakeValue, Fetch.parse(a, &.{"--verify-only=true"}));
}

test "runner requires paths and validates native selection and timeout before VM initialization" {
    const a = std.testing.allocator;
    const required = [_][]const u8{ "--base", "baseline", "--stage", "binaries", "--out", "new run" };
    try std.testing.expectError(error.BaseRequired, Runner.parse(a, &.{}));
    try std.testing.expectError(error.StageRequired, Runner.parse(a, &.{ "--base", "baseline" }));
    try std.testing.expectError(error.OutputRequired, Runner.parse(a, &.{ "--base", "baseline", "--stage", "binaries" }));
    var parsed = try Runner.parse(a, &(required ++ [_][]const u8{ "--native", "skip", "--timeout", "3600", "--user", "tester", "--cases", "accept,undo" }));
    defer parsed.deinit();
    try std.testing.expectEqual(Runner.Native.skip, parsed.args.native.?);
    try std.testing.expectEqual(@as(?u32, 3600), parsed.args.timeout);
    try std.testing.expectEqualStrings("tester", parsed.args.user.?);
    try std.testing.expectEqualStrings("accept,undo", parsed.args.cases.?);
    try std.testing.expectError(error.InvalidNativeSelection, Runner.parse(a, &(required ++ [_][]const u8{ "--native", "unknown" })));
    try std.testing.expectError(error.InvalidTimeout, Runner.parse(a, &(required ++ [_][]const u8{ "--timeout", "0" })));
    try std.testing.expectError(error.InvalidTimeout, Runner.parse(a, &(required ++ [_][]const u8{ "--timeout", "3601" })));
    try std.testing.expectError(error.Overflow, Runner.parse(a, &(required ++ [_][]const u8{ "--timeout", "4294967296" })));
}

test "guest preserves the five positional protocol and validates actions" {
    const a = std.testing.allocator;
    inline for (std.meta.tags(Guest.Action)) |action| {
        var parsed = try Guest.parse(a, &.{ @tagName(action), "C:\\work path", "serial", "wwn", "accept" });
        defer parsed.deinit();
        try std.testing.expectEqual(action, parsed.positionals[0].?);
        try std.testing.expectEqualStrings("C:\\work path", parsed.positionals[1].?);
        try std.testing.expectEqualStrings("serial", parsed.positionals[2].?);
        try std.testing.expectEqualStrings("wwn", parsed.positionals[3].?);
        try std.testing.expectEqualStrings("accept", parsed.positionals[4].?);
    }
    try std.testing.expectError(error.ExpectedActionWorkSerialWwnCase, Guest.parse(a, &.{}));
    try std.testing.expectError(error.ExpectedActionWorkSerialWwnCase, Guest.parse(a, &.{ "setup", "work", "serial", "wwn" }));
    try std.testing.expectError(error.UnexpectedArgument, Guest.parse(a, &.{ "setup", "work", "serial", "wwn", "case", "extra" }));
    try std.testing.expectError(error.UnknownAction, Guest.parse(a, &.{ "unknown", "work", "serial", "wwn", "case" }));
    var escaped = try Guest.parse(a, &.{ "--", "setup", "work", "serial", "wwn", "--case" });
    defer escaped.deinit();
    try std.testing.expectEqualStrings("--case", escaped.positionals[4].?);
}

test "all VM tools accept help and reject unknown options and missing values" {
    const a = std.testing.allocator;
    inline for (.{ Artifacts, Fetch, Runner, Guest }) |Command| {
        inline for (.{ "-h", "--help" }) |flag| {
            var parsed = try Command.parse(a, &.{flag});
            defer parsed.deinit();
            try std.testing.expect(parsed.args.help != 0);
        }
        try std.testing.expectError(error.InvalidArgument, Command.parse(a, &.{"--unknown"}));
    }
    try std.testing.expectError(error.MissingValue, Artifacts.parse(a, &.{"--out"}));
    try std.testing.expectError(error.MissingValue, Fetch.parse(a, &.{"--config"}));
    try std.testing.expectError(error.MissingValue, Runner.parse(a, &.{"--base"}));
    try std.testing.expectError(error.InvalidArgument, Artifacts.parse(a, &.{"extra"}));
    try std.testing.expectError(error.InvalidArgument, Fetch.parse(a, &.{"extra"}));
    try std.testing.expectError(error.InvalidArgument, Runner.parse(a, &.{"extra"}));
}

test "artifact and runner duplicate rejection includes assignment syntax" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnknownOrDuplicateOption, Artifacts.parse(a, &.{ "--out", "first", "--out=second" }));
    try std.testing.expectError(error.UnknownOrDuplicateOption, Runner.parse(a, &.{ "--base=first", "--base", "second" }));
}
