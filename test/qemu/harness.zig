const std = @import("std");
const utils = @import("utils");

fn ovmfPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
) ![2][]const u8 {
    if (environ.get("OVMF_CODE")) |code| {
        if (code.len > 0)
            if (environ.get("OVMF_VARS")) |variables| {
                if (variables.len > 0)
                    return .{ code, variables };
            };
    }
    for ([_][3][]const u8{
        .{
            "/usr/share/OVMF/x64",
            "OVMF_CODE.4m.fd",
            "OVMF_VARS.4m.fd",
        },
        .{
            "/usr/share/OVMF",
            "OVMF_CODE_4M.fd",
            "OVMF_VARS_4M.fd",
        },
        .{
            "/usr/share/OVMF",
            "OVMF_CODE.fd",
            "OVMF_VARS.fd",
        },
        .{
            "/usr/share/edk2/ovmf",
            "OVMF_CODE.fd",
            "OVMF_VARS.fd",
        },
    }) |entry| {
        const code = try std.fs.path.join(allocator, &.{ entry[0], entry[1] });
        const variables = try std.fs.path.join(allocator, &.{ entry[0], entry[2] });
        const code_stat = std.Io.Dir.cwd().statFile(io, code, .{}) catch continue;
        if (code_stat.kind != .file) continue;
        const variables_stat = std.Io.Dir.cwd().statFile(io, variables, .{}) catch continue;
        if (variables_stat.kind == .file)
            return .{
                code,
                variables,
            };
    }
    return error.OvmfMissingSetCodeAndVars;
}

/// Rejects commas in paths embedded in QEMU comma-separated option values.
pub fn noComma(path: []const u8) !void {
    if (std.mem.indexOfScalar(u8, path, ',') != null)
        return error.QemuPathContainsComma;
}

/// Builds an allocator-backed QEMU q35/TCG command with a private copy of OVMF variables.
/// Uses two CPUs and the requested memory; callers append kernel, disk and network options.
pub fn baseCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    directory: []const u8,
    memory_mib: u32,
) !std.array_list.Managed([]const u8) {
    const firmware = try ovmfPaths(allocator, io, environ);
    const variables = try std.fs.path.join(
        allocator,
        &.{ directory, "OVMF_VARS.fd" },
    );
    try noComma(firmware[0]);
    try noComma(variables);
    try std.Io.Dir.cwd().copyFile(
        firmware[1],
        .cwd(),
        variables,
        io,
        .{ .make_path = true },
    );
    var command: std.array_list.Managed([]const u8) = .init(allocator);
    try command.appendSlice(
        &.{
            "qemu-system-x86_64",
            "-machine",
            "q35",
            "-accel",
            "tcg",
            "-cpu",
            "max",
            "-m",
            try allocator.print("{d}", .{memory_mib}),
            "-smp",
            "2",
            "-drive",
            try allocator.print(
                "if=pflash,format=raw,readonly=on,file={s}",
                .{firmware[0]},
            ),
            "-drive",
            try allocator.print(
                "if=pflash,format=raw,file={s}",
                .{variables},
            ),
            "-display",
            "none",
            "-serial",
            "stdio",
            "-monitor",
            "none",
        },
    );
    return command;
}

fn pause(io: std.Io, seconds: i64) !void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
}

fn waitExited(io: std.Io, pid: std.os.linux.pid_t) !void {
    // WNOWAIT keeps ownership of the PID until the parent chooses the winner.
    // Canceling Child.wait on this nightly would otherwise forget a live child.
    while (true) {
        var info = std.mem.zeroes(std.os.linux.siginfo_t);
        const result = std.os.linux.waitid(
            .PID,
            @intCast(pid),
            &info,
            std.os.linux.W.EXITED | std.os.linux.W.NOWAIT | std.os.linux.W.NOHANG,
            null,
        );
        switch (std.os.linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ChildStatusFailed,
        }
        if (info.fields.common.first.piduid.pid != 0)
            return;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
}

/// Runs a VM command with stdout and stderr written to serial.log in the supplied directory.
/// On timeout, cancels the status watcher, kills and reaps the child, and returns Timeout.
/// Returns an allocator-owned log on a zero exit; diagnostic logs remain on disk after failure.
pub fn runVm(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    command: []const []const u8,
    directory: []const u8,
    timeout_s: u32,
) ![]const u8 {
    const log = try std.fs.path.join(
        allocator,
        &.{ directory, "serial.log" },
    );
    const file = try std.Io.Dir.cwd().createFile(io, log, .{});
    defer file.close(io);
    var child = try std.process.spawn(
        io,
        .{
            .argv = command,
            .stdin = .ignore,
            .stdout = .{ .file = file },
            .stderr = .{ .file = file },
            .environ_map = environ,
        },
    );
    defer child.kill(io);
    const Outcome = union(enum) { finished: anyerror!void, timeout: anyerror!void };
    var buffer: [2]Outcome = undefined;
    var select: std.Io.Select(Outcome) = .init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(
        .finished,
        waitExited,
        .{ io, child.id.? },
    );
    try select.concurrent(
        .timeout,
        pause,
        .{ io, @as(i64, timeout_s) },
    );
    switch (try select.await()) {
        .finished => |result| {
            try result;
            const term = try child.wait(io);
            if (term != .exited or term.exited != 0) {
                std.log.err("QEMU failed; inspect {s}", .{log});
                return error.QemuFailed;
            }
        },
        .timeout => |result| {
            try result;
            select.cancelDiscard();
            if (std.os.linux.errno(std.os.linux.kill(child.id.?, .KILL)) != .SUCCESS) {
                return error.ChildKillFailed;
            }
            _ = try child.wait(io);
            std.log.warn("VM timed out; inspect {s}", .{log});
            return error.Timeout;
        },
    }
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        log,
        allocator,
        .limited(128 * 1024 * 1024),
    );
}

test "child-process deadline retains diagnostics and kills the timed-out process" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var env = try std.testing.environ.createMap(allocator);
    const environ = &env;
    const directory = try utils.filesystem.createTemporaryDirectory(
        allocator,
        io,
        "pizza-timeout-test-",
    );
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch |err| std.log.warn("Cleanup {s}: {t}", .{ directory, err });
    const serial = try runVm(
        allocator,
        io,
        environ,
        &.{
            "sh",
            "-c",
            "printf 'native-child-ok\\n'",
        },
        directory,
        5,
    );
    try std.testing.expectEqualStrings("native-child-ok\n", serial);
    try std.testing.expectError(
        error.Timeout,
        runVm(
            allocator,
            io,
            environ,
            &.{
                "sh",
                "-c",
                "echo child_pid:$$; exec sleep 60",
            },
            directory,
            1,
        ),
    );
    const log = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fs.path.join(
            allocator,
            &.{ directory, "serial.log" },
        ),
        allocator,
        .limited(128 * 1024 * 1024),
    );
    const pid = try std.fmt.parseInt(
        i32,
        std.mem.trim(u8, log["child_pid:".len..], " \t\r\n"),
        10,
    );
    try std.testing.expectEqual(
        std.os.linux.E.SRCH,
        std.os.linux.errno(
            std.os.linux.kill(pid, @fromBackingInt(0)),
        ),
    );
}
