//! Disposable VM PID 1; only /dev/vda, supplied by the test runner, is mounted.
const std = @import("std");
const linux = std.os.linux;
const journal = @import("journal");
const proto = @import("proto");
const supervisor = @import("supervisor");
const power = @import("power");
const utils = @import("utils");
const names = [_][]const u8{ "success", "failure", "hang", "fsync", "short" };

pub fn main(init: std.process.Init) !void {
    if (linux.getpid() != 1) return error.NotPid1;
    supervisor.installSignals() catch {};
    run(init.arena.allocator(), init.io) catch |err| std.log.err("PIZZA_EXECUTOR_TEST_FAILED: {t}", .{err});
    power.poweroff() catch {};
    supervisor.degraded();
}
fn spawn(a: std.mem.Allocator, argv: []const []const u8) !linux.pid_t {
    const args = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| args[i] = (try a.dupeSentinel(u8, arg, 0)).ptr;
    const env = [_:null]?[*:0]const u8{ "PATH=/opt/pizza/bundle/bin", "HOME=/run/pizza", "TMPDIR=/tmp", "LC_ALL=C", "XDG_RUNTIME_DIR=/run/pizza", "XDG_CACHE_HOME=/run/pizza/cache", "WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1" };
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.execve("bin/pizza-maint", args.ptr, &env);
        linux.exit(127);
    }
    return @intCast(pid);
}
fn wait(pid: linux.pid_t, kill_after_ms: i64) !i32 {
    const start = try supervisor.milliseconds();
    var killed = false;
    while (true) {
        while (try supervisor.reap()) |child| if (child.pid == pid) return child.status;
        if (!killed and try supervisor.milliseconds() - start > kill_after_ms) {
            if (linux.errno(linux.kill(pid, .KILL)) != .SUCCESS) return error.ChildKillFailed;
            killed = true;
        }
        if (try supervisor.milliseconds() - start > kill_after_ms + 5000) return error.ChildTimedOut;
        supervisor.sleep();
    }
}
fn verify(a: std.mem.Allocator, io: std.Io, path: []const u8, index: usize, boot_id: []const u8, recovered: bool) !void {
    const value = try journal.readFile(a, io, path);
    if (recovered and std.mem.eql(u8, value.state.boundary.?.boot_id, boot_id)) return error.TestNeedsDifferentBoot;
    if (index == 0) {
        if (!value.state.complete or value.state.seq != 42 or value.state.steps.count() != 20) return error.BadSuccess;
        for (value.state.steps.values()) |step| if (step.state != .succeeded) return error.BadSuccess;
    } else {
        if (value.state.complete or value.state.steps.get(7).?.state != .succeeded or value.state.steps.contains(9)) return error.PlanDidNotStop;
        if (index == 1 and value.state.steps.get(8).?.state != .failed) return error.BadFailure;
        if ((index == 2 or index == 3) and value.state.steps.get(8).?.state != .in_flight) return error.BadInterruption;
        if (index == 4 and (value.state.steps.contains(8) or value.tail != .short_header or value.state.seq != 15)) return error.BadTornTail;
    }
    if (index != 4 and value.tail != .clean) return error.UnexpectedTail;
}
fn run(a: std.mem.Allocator, io: std.Io) !void {
    try @import("mounts").setup(io);
    try std.Io.Dir.cwd().createDirPath(io, "/journal");
    if (linux.errno(linux.mount("/dev/vda", "/journal", "ext4", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, 0)) != .SUCCESS) return error.TestJournalMountFailed;
    if (linux.errno(linux.chdir("/opt/pizza/bundle")) != .SUCCESS) return error.BundleWorkingDirectoryUnavailable;
    const command = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/cmdline", a, .limited(16384));
    const reading = std.mem.indexOf(u8, command, "pizza.executor_test=read") != null;
    if (!reading and std.mem.indexOf(u8, command, "pizza.executor_test=write") == null) return error.MissingMode;
    const steps = try a.alloc(proto.wire.Step, 20);
    for (steps, 0..) |*step, i| step.* = .{ .id = @intCast(i + 1), .label = try a.print("Simulated VM step {d}", .{i + 1}), .simulated = true };
    const plan: proto.Plan = .{ .id = "qemu_executor", .version = proto.api_version, .steps = steps };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/run/pizza/plan.json", .data = try std.json.Stringify.valueAlloc(a, plan, .{}) });
    const anchor = try journal.captureBoundary(a, io, .{ .state = .start, .boot_id = "", .utc_unix_ns = "", .plan_id = plan.id, .home = .{ .kind = .other_device, .path = "/journal" } });
    if (!reading) {
        for (names) |name| try std.Io.Dir.cwd().createDir(io, try a.print("/journal/{s}", .{name}), .fromMode(0o700));
        const parent = try std.Io.Dir.cwd().openFile(io, "/journal", .{ .allow_directory = true });
        try parent.sync(io);
        parent.close(io);
    }
    for (names, 0..) |name, index| {
        const home = try a.print("/journal/{s}", .{name});
        const path = try a.print("{s}/journal.bin", .{home});
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ "bin/pizza-maint", "--execute", "--plan", "/run/pizza/plan.json", "--journal-home", home, "--step-delay-ms", if ((index == 0 or index == 3) and !reading) "250" else "0" });
        if (!reading and (index == 0 or index == 3)) {
            try args.appendSlice(a, &.{ "--self-test", "--headless", "--timeout", "60" });
        } else try args.appendSlice(a, &.{ "--no-ui", "--exit-after-plan" });
        if (!reading) switch (index) {
            1 => try args.appendSlice(a, &.{ "--step-fail", "8" }),
            2 => try args.appendSlice(a, &.{ "--step-hang", "8" }),
            3 => try args.appendSlice(a, &.{ "--fsync-fail-step", "8" }),
            4 => try args.appendSlice(a, &.{ "--short-write-step", "8" }),
            else => {},
        };
        const before = if (reading) try utils.filesystem.hashFileSha256(a, io, path) else "";
        const status = try wait(try spawn(a, args.items), if (!reading and index == 2) 3000 else 75000);
        const expected: i32 = if (reading or index == 1 or index == 3 or index == 4) 256 else if (index == 2) 9 else 0;
        if (status != expected) {
            std.log.err("case={s} wait={d} expected={d}", .{ name, status, expected });
            return error.UnexpectedApplicationExit;
        }
        try verify(a, io, path, index, anchor.boundary.boot_id, reading);
        if (reading and !std.mem.eql(u8, before, try utils.filesystem.hashFileSha256(a, io, path))) return error.RecoveryChangedJournal;
        std.log.info("PIZZA_EXECUTOR_CASE_READY: {s}; recovery={}", .{ name, reading });
    }
    if (linux.errno(linux.umount2("/journal", 0)) != .SUCCESS) return error.TestUnmountFailed;
    std.log.info("PIZZA_EXECUTOR_UNMOUNTED", .{});
    std.log.info("PIZZA_EXECUTOR_READY: {s}", .{if (reading) "read" else "write"});
}
