//! Single PID 1 reaper. Signal handlers only set flags; all work runs in the loop.
const std = @import("std");
const linux = std.os.linux;

var received: u32 = 0;

fn handle(signal: linux.SIG) callconv(.c) void {
    _ = @atomicRmw(u32, &received, .Or, @as(u32, 1) << @intCast(@backingInt(signal) - 1), .monotonic);
}

pub fn installSignals() !void {
    const action: linux.Sigaction = .{ .handler = .{ .handler = handle }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .CHLD, .TERM, .INT, .HUP, .USR1, .USR2 }) |signal|
        if (linux.errno(linux.sigaction(signal, &action, null)) != .SUCCESS) return error.SignalSetupFailed;
}

pub fn takeSignals() u32 {
    return @atomicRmw(u32, &received, .Xchg, 0, .monotonic);
}

pub const Exit = struct { pid: linux.pid_t, status: i32 };

/// Reaps any child, including orphans adopted by PID 1. Never blocks.
pub fn reap() !?Exit {
    while (true) {
        var status: i32 = 0;
        const result = linux.waitpid(-1, &status, linux.W.NOHANG);
        switch (linux.errno(result)) {
            .SUCCESS => return if (result == 0) null else .{ .pid = @intCast(result), .status = status },
            .INTR => continue,
            .CHILD => return null,
            else => return error.ReapFailed,
        }
    }
}

/// Only async-signal-safe syscalls run between fork and exec. Children inherit
/// the bundle CWD and get a small explicit environment instead of the host's.
pub fn probe() !linux.pid_t {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        const args = [_:null]?[*:0]const u8{ "bin/bwrap", "--version" };
        const env = [_:null]?[*:0]const u8{ "PATH=/opt/pizza/bundle/bin", "HOME=/run/pizza", "TMPDIR=/tmp", "LC_ALL=C" };
        _ = linux.execve("bin/bwrap", &args, &env);
        linux.exit(127);
    }
    return @intCast(pid);
}

/// VM-only orphan fixture. The intermediate parent exits before its child;
/// the grandchild must then be collected by the PID 1 supervisor.
pub fn orphan() !linux.pid_t {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        const child = linux.fork();
        if (linux.errno(child) != .SUCCESS) linux.exit(126);
        if (child == 0) {
            var delay: linux.timespec = .{ .sec = 1, .nsec = 0 };
            while (linux.errno(linux.nanosleep(&delay, &delay)) == .INTR) {}
            linux.exit(0);
        }
        linux.exit(0);
    }
    return @intCast(pid);
}

pub fn milliseconds() !i64 {
    var now: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS) return error.ClockFailed;
    return now.sec * 1000 + @divTrunc(now.nsec, 1000000);
}

pub fn sleep() void {
    const delay: linux.timespec = .{ .sec = 0, .nsec = 100000000 };
    _ = linux.nanosleep(&delay, null);
}

/// The failure state never returns or requests a reboot. Continue collecting
/// children so an initialization error cannot kill PID 1 or accumulate zombies.
pub fn degraded() noreturn {
    while (true) {
        while (reap() catch null) |_| {}
        _ = takeSignals();
        sleep();
    }
}

pub const ApplicationMode = enum { ui, no_ui, test_exit, bridge_test, session };

/// The ordinary application owns business logic and WPE. This static supervisor
/// only launches and reaps it; a crash never authorizes a reboot or plan retry.
pub fn application(mode: ApplicationMode) !linux.pid_t {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        const arg: [*:0]const u8 = switch (mode) {
            .ui => "--panel",
            .no_ui => "--no-ui",
            .test_exit => "--test-exit",
            .bridge_test => "--self-test",
            .session => "--session",
        };
        const ui_args = [_:null]?[*:0]const u8{ "bin/pizza-maint", "--panel", "share/panel/index.html" };
        const simple_args = [_:null]?[*:0]const u8{ "bin/pizza-maint", arg };
        const test_args = [_:null]?[*:0]const u8{ "bin/pizza-maint", "--self-test", "--headless", "--timeout", "90" };
        const normal_env = [_:null]?[*:0]const u8{
            "PATH=/opt/pizza/bundle/bin", "HOME=/run/pizza",                 "TMPDIR=/tmp",                   "LC_ALL=C",
            "XDG_RUNTIME_DIR=/run/pizza", "XDG_CACHE_HOME=/run/pizza/cache", "XDG_DATA_HOME=/run/pizza/data", "XDG_CONFIG_HOME=/run/pizza/config",
        };
        // Only the explicitly selected VM bridge fixture disables the WebKit
        // sandbox, to test the bridge independently from kernel namespace policy.
        const test_env = [_:null]?[*:0]const u8{
            "PATH=/opt/pizza/bundle/bin",                 "HOME=/run/pizza",                 "TMPDIR=/tmp",                   "LC_ALL=C",
            "XDG_RUNTIME_DIR=/run/pizza",                 "XDG_CACHE_HOME=/run/pizza/cache", "XDG_DATA_HOME=/run/pizza/data", "XDG_CONFIG_HOME=/run/pizza/config",
            "WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1",
        };
        _ = linux.execve("bin/pizza-maint", switch (mode) {
            .ui => &ui_args,
            .bridge_test => &test_args,
            else => &simple_args,
        }, if (mode == .bridge_test) &test_env else &normal_env);
        linux.exit(127);
    }
    return @intCast(pid);
}
