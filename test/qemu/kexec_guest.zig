//! Disposable VM fixture. Production stage/load/session code runs unmodified.
const std = @import("std");
const linux = std.os.linux;
const session = @import("session");
const utils = @import("utils");
const journal = @import("journal");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (std.mem.eql(u8, args[0], "systemctl") or std.mem.endsWith(u8, args[0], "/fake/systemctl")) return 17;
    if (linux.getpid() == 1) try @import("mounts").setup(init.io);
    const command_line = try session.readProc(a, init.io, "/proc/cmdline", 16384);
    if (std.mem.indexOf(u8, command_line, "pizza.kexec_fixture=1") == null) {
        std.log.err("This fixture requires an explicitly marked disposable VM", .{});
        return 1;
    }
    run(init, args) catch |err| {
        std.log.err("PIZZA_KEXEC_TEST_FAILED: {t}", .{err});
        _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
        return 1;
    };
    return 0;
}
fn run(init: std.process.Init, args: []const []const u8) !void {
    const a = init.arena.allocator();
    const io = init.io;
    if (linux.getpid() == 1) {
        const line = try session.readProc(a, io, "/proc/cmdline", 16384);
        if (std.mem.indexOf(u8, line, "pizza.kexec_report=1") != null) {
            try mount(io, "/dev/vdb", "/journal", true);
            const path = "/journal/pizza-session/journal.bin";
            const hash = try utils.filesystem.hashFileSha256(a, io, path);
            const value = try journal.readFile(a, io, path);
            if (!value.state.complete or value.state.seq != 42 or value.state.steps.count() != 20) return error.BadRecoveredJournal;
            var directory = try session.storage.openTrusted(io, "/journal/pizza-session");
            defer directory.close(io);
            const marker = try session.readMarker(a, io, directory);
            if (marker.status != .completed or marker.maintenance_boot_id == null or std.mem.eql(u8, marker.request.source_boot_id, marker.maintenance_boot_id.?)) return error.BadTransitionMarker;
            const report_bytes = try utils.process.checkedOutput(a, io, init.environ_map, &.{ "/pizza", "transition", "report", "--journal", path });
            const report = try std.json.parseFromSliceLeaky(std.json.Value, a, report_bytes, .{});
            if (!std.mem.eql(u8, report.object.get("transition").?.object.get("reconciled_status").?.string, "completed")) return error.BadReconciledReport;
            if (!std.mem.eql(u8, hash, try utils.filesystem.hashFileSha256(a, io, path))) return error.ReportModifiedJournal;
            std.log.info("PIZZA_KEXEC_RECOVERY_READY: completed marker, 20 commits, read-only report", .{});
            directory.close(io);
            // Avoid double close by powering off immediately after durability checks.
            if (linux.errno(linux.umount2("/journal", 0)) != .SUCCESS) return error.UnmountFailed;
            _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
            while (true) {}
        }
        try std.Io.Dir.cwd().createDirPath(io, "/sys/fs/cgroup");
        if (linux.errno(linux.mount("cgroup2", "/sys/fs/cgroup", "cgroup2", 0, 0)) != .SUCCESS) return error.CgroupMountFailed;
        const argv = [_:null]?[*:0]const u8{ "/usr/lib/systemd/systemd", "--unit=pizza-test.target", "--log-target=console", "--log-level=debug" };
        const env = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", "HOME=/", "TERM=linux", "LC_ALL=C" };
        _ = linux.execve(argv[0].?, &argv, &env);
        return error.SystemdExecFailed;
    }
    if (args.len != 2 or !std.mem.eql(u8, args[1], "run")) return error.InvalidFixtureArguments;
    const deny = std.mem.indexOf(u8, try session.readProc(a, io, "/proc/cmdline", 16384), "pizza.kexec_deny=1") != null;
    const home_path = if (deny) "/journal/pizza-denied" else "/journal/pizza-session";
    try mount(io, "/dev/vda", "/original", true);
    try mount(io, "/dev/vdb", "/journal", false);
    try std.Io.Dir.cwd().createDir(io, home_path, .fromMode(0o700));
    var directory = try session.storage.openTrusted(io, "/journal");
    defer directory.close(io);
    try session.syncDir(io, directory);
    const steps = try a.alloc(@import("proto").wire.Step, 20);
    for (steps, 0..) |*step, i| step.* = .{ .id = @intCast(i + 1), .label = "Real handoff simulated step", .simulated = true };
    const plan: @import("proto").Plan = .{ .id = "production_handoff", .version = 1, .steps = steps };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/run/plan.json", .data = try std.json.Stringify.valueAlloc(a, plan, .{}) });
    _ = try utils.process.checkedOutput(a, io, init.environ_map, &.{ "/pizza", "transition", "build", "--kernel", "/kernel", "--initrd", "/maintenance.img", "--plan", "/run/plan.json", "--journal-device", "/dev/vdb", "--journal-home", home_path, "--no-ui", "--test-poweroff" });
    if (deny) {
        const disabled = try std.Io.Dir.cwd().openFile(io, "/proc/sys/kernel/kexec_load_disabled", .{ .mode = .write_only });
        try disabled.writeStreamingAll(io, "1");
        disabled.close(io);
        const refused = try std.process.run(a, io, .{ .argv = &.{ "/pizza", "transition", "transition" }, .environ_map = init.environ_map });
        if (refused.term != .exited or refused.term.exited != 1 or std.mem.indexOf(u8, refused.stderr, "KexecPermissionOrLockdown") == null) return error.ExpectedLoadPermissionRefusal;
        var home = try session.storage.openTrusted(io, home_path);
        if ((try session.readMarker(a, io, home)).status != .staged) return error.LoadRefusalChangedMarker;
        if (!std.mem.eql(u8, std.mem.trim(u8, try session.readProc(a, io, "/sys/kernel/kexec_loaded", 16), "\r\n"), "0")) return error.LoadRefusalLeftKernelLoaded;
        const report = try utils.process.checkedOutput(a, io, init.environ_map, &.{ "/pizza", "transition", "report", "--journal-home", home_path });
        const value = try std.json.parseFromSliceLeaky(std.json.Value, a, report, .{});
        if (!value.object.get("transition").?.object.get("journal_missing").?.bool) return error.MissingJournalReport;
        home.close(io);
        directory.close(io);
        if (linux.errno(linux.umount2("/journal", 0)) != .SUCCESS) return error.UnmountFailed;
        std.log.info("PIZZA_KEXEC_DENIED_READY: no loaded kernel, no journal, staged marker preserved", .{});
        _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
        while (true) {}
    }
    // Exercise a real successful load followed by a rejected shutdown request.
    var fake_env = try init.environ_map.clone(a);
    try fake_env.put("PATH", "/fake:/usr/bin");
    const refused = try std.process.run(a, io, .{ .argv = &.{ "/pizza", "transition", "transition" }, .environ_map = &fake_env });
    if (refused.term != .exited or refused.term.exited != 1) return error.ExpectedShutdownRefusal;
    if (!std.mem.eql(u8, std.mem.trim(u8, try session.readProc(a, io, "/sys/kernel/kexec_loaded", 16), "\r\n"), "0")) return error.RollbackLeftKernelLoaded;
    var home = try session.storage.openTrusted(io, "/journal/pizza-session");
    defer home.close(io);
    if ((try session.readMarker(a, io, home)).status != .staged) return error.RollbackLeftLoadedMarker;
    std.log.info("PIZZA_KEXEC_ROLLBACK_READY: kernel unloaded and marker restored after refusal", .{});
    std.log.info("PIZZA_KEXEC_FIRST_BOOT: systemd PID 1; original disk mounted read-only", .{});
    try utils.process.runInherited(io, init.environ_map, &.{ "/pizza", "transition", "transition" });
}
fn mount(io: std.Io, source: [:0]const u8, path: [:0]const u8, readonly: bool) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
    const flags: u32 = linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC | (if (readonly) @as(u32, linux.MS.RDONLY) else 0);
    const result = linux.mount(source, path, "ext4", flags, if (readonly) @intFromPtr("noload") else 0);
    if (linux.errno(result) != .SUCCESS) return error.FixtureMountFailed;
}
