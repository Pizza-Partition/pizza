const std = @import("std");
const linux = std.os.linux;
const bundle = @import("bundle");
const power = @import("power");
const cmdline = @import("cmdline.zig");
const mounts = @import("mounts.zig");
const modules = @import("modules.zig");
const supervisor = @import("supervisor.zig");

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(message: []const u8, trace: ?usize) noreturn {
    if (linux.getpid() != 1) std.debug.defaultPanic(message, trace);
    // Avoid allocator and logging locks in the emergency path.
    const prefix = "PIZZA_MAINT_PANIC: PID 1 remains alive: ";
    _ = linux.write(2, prefix, prefix.len);
    _ = linux.write(2, message.ptr, message.len);
    _ = linux.write(2, "\n", 1);
    supervisor.degraded();
}

/// Runs a RAM-only maintenance PID 1. Initialization failures retain a live,
/// diagnostic supervisor; only explicitly selected VM tests request poweroff.
pub fn main(init: std.process.Init) !void {
    if (linux.getpid() != 1) return error.NotPid1;
    supervisor.installSignals() catch |err| fail(err);
    run(init.arena.allocator(), init.io) catch |err| fail(err);
    supervisor.degraded();
}

fn fail(err: anyerror) noreturn {
    std.log.err("PIZZA_MAINT_DEGRADED: {t}; PID 1 remains alive; executor disabled", .{err});
    supervisor.degraded();
}

fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    try mounts.setup(io);
    const line = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/cmdline", allocator, .limited(16 * 1024));
    defer allocator.free(line);
    const parameters = try cmdline.parse(line);
    // These settings are parsed now; their consumers belong to later phases.
    // No nonce, full command line or session identifier is written to the console.
    std.log.info("PIZZA_MAINT_CMDLINE_READY: boot={t}", .{parameters.boot});
    if (parameters.boot == .smoke) {
        std.log.info("PIZZA_MAINT_SMOKE_READY", .{});
        try power.poweroff();
        return;
    }
    const module_count = try modules.load(allocator, io);
    if (linux.errno(linux.chdir(bundle.prefix)) != .SUCCESS) return error.BundleWorkingDirectoryUnavailable;
    var root = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer root.close(io);
    const fs = @import("utils").filesystem;
    const kind = try fs.filesystemType(root);
    if (kind != fs.tmpfs_magic and kind != fs.ramfs_magic) return error.BundleMustBeRam;
    std.log.info("PIZZA_MAINT_BUNDLE_CWD_READY", .{});
    if (parameters.boot == .selftest) {
        if (module_count == 0) return error.TestNeedsLoadableModule;
        try selftest(io);
        return;
    }
    if (parameters.boot == .bridge_test) {
        const app = try supervisor.application(.bridge_test);
        while (true) {
            while (try supervisor.reap()) |child| {
                if (child.pid != app) continue;
                if (child.status != 0) {
                    std.log.err("Bridge application wait status={d}", .{child.status});
                    return error.BridgeApplicationFailed;
                }
                std.log.info("PIZZA_INIT_BRIDGE_CHILD_READY: application completed and reaped", .{});
                try power.poweroff();
                return;
            }
            supervisor.sleep();
        }
    }
    const handoff = if (std.Io.Dir.cwd().access(io, "/etc/pizza/session.json", .{})) true else |err| blk: {
        if (err != error.FileNotFound) return err;
        break :blk false;
    };
    if (parameters.plan_id != null and !handoff) return error.MissingProtectedHandoff;
    if (parameters.boot == .transition_test and !handoff) return error.MissingProtectedHandoff;
    const application = try supervisor.application(if (handoff) .session else if (parameters.kiosk == .disabled) .no_ui else .ui);
    std.log.info("PIZZA_MAINT_READY: application PID {d}; static supervisor active", .{application});
    while (true) {
        while (try supervisor.reap()) |child| {
            if (child.pid == application and parameters.boot == .transition_test) {
                if (child.status != 0) return error.TransitionApplicationFailed;
                std.log.info("PIZZA_TRANSITION_MAINTENANCE_READY: real session completed and reaped", .{});
                try power.poweroff();
                return;
            }
            if (child.pid == application)
                std.log.err("PIZZA_INIT_APPLICATION_EXITED: status={d}; PID 1 remains alive; no automatic plan retry", .{child.status})
            else
                std.log.info("Adopted child {d} exited: {d}", .{ child.pid, child.status });
        }
        if (supervisor.takeSignals() != 0)
            std.log.info("Maintenance supervisor received signal; remaining available", .{});
        supervisor.sleep();
    }
}

fn selftest(io: std.Io) !void {
    // This disk is a disposable QEMU fixture. Merely stat it; never open it for IO.
    const deadline = try supervisor.milliseconds() + 10000;
    while (true) {
        const device = std.Io.Dir.cwd().statFile(io, "/dev/vda", .{}) catch |err| {
            if (err != error.FileNotFound) return err;
            if (try supervisor.milliseconds() >= deadline) return error.TestBlockDeviceMissing;
            supervisor.sleep();
            continue;
        };
        if (device.kind != .block_device) return error.TestBlockDeviceMissing;
        break;
    }
    std.log.info("PIZZA_MAINT_DEVICE_READY: /dev/vda", .{});
    const probe = try supervisor.probe();
    const parent = try supervisor.orphan();
    const application = try supervisor.application(.test_exit);
    var application_done = false;
    var probe_done = false;
    var parent_done = false;
    var orphan_done = false;
    var signals: u32 = 0;
    const requested_signals: u32 = (@as(u32, 1) << (@backingInt(linux.SIG.TERM) - 1)) | (@as(u32, 1) << (@backingInt(linux.SIG.INT) - 1));
    if (linux.errno(linux.kill(linux.getpid(), .TERM)) != .SUCCESS or linux.errno(linux.kill(linux.getpid(), .INT)) != .SUCCESS)
        return error.TestSignalFailed;
    const start = try supervisor.milliseconds();
    while (true) {
        while (try supervisor.reap()) |child| {
            if (child.pid == application) {
                if (child.status != (17 << 8)) return error.TestApplicationDidNotFailAsExpected;
                application_done = true;
                std.log.info("PIZZA_INIT_APPLICATION_EXIT_OBSERVED: failed child reaped; PID 1 remains alive", .{});
                continue;
            }
            if (child.status != 0) return error.TestChildFailed;
            if (child.pid == probe) {
                probe_done = true;
                std.log.info("PIZZA_MAINT_DYNAMIC_PROBE_READY", .{});
            } else if (child.pid == parent) {
                parent_done = true;
            } else {
                orphan_done = true;
            }
        }
        signals |= supervisor.takeSignals();
        const elapsed = try supervisor.milliseconds() - start;
        if (application_done and probe_done and parent_done and orphan_done and signals & requested_signals == requested_signals and elapsed >= 3000) break;
        if (elapsed > 10000) return error.TestChildrenTimedOut;
        supervisor.sleep();
    }
    std.log.info("PIZZA_MAINT_REAPER_READY: child and adopted orphan collected", .{});
    std.log.info("PIZZA_MAINT_SIGNALS_READY: TERM and INT handled", .{});
    std.log.info("PIZZA_MAINT_SELFTEST_READY: supervisor alive for at least 3 seconds", .{});
    try power.poweroff();
}
