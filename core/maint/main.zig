//! Ordinary maintenance application: business state, journal and WPE share one process.
const std = @import("std");
const clap = @import("clap");
const bridge = @import("maintenance").bridge;
const gui = @import("execution_gui");
const proto = @import("proto");
const journal = @import("journal");
const plan_module = @import("maintenance").plan;
const tui = @import("execution_tui");
const session = @import("session");
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;

const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--panel <str>  Local panel entry (default: share/panel/index.html).
    \\--wpe-library <str>  WPE 2.0 library (default: lib/libWPEWebKit-2.0.so.1).
    \\--session  Use the protected kexec handoff; mount its journal and execute once.
    \\--plan <str>  Validated simulated plan JSON.
    \\--journal <str>  Journal to display and replay.
    \\--execute  Explicitly execute a new simulated plan; never resume an existing journal.
    \\--journal-home <str>  Existing trusted directory on ext4, XFS or Btrfs for new execution.
    \\--step-delay-ms <u32>  Simulated delay per step, 0-60000 (default: 250).
    \\--step-fail <u32>  Inject failure at step ordinal 1-20.
    \\--step-hang <u32>  Inject a nonblocking hang at step ordinal 1-20.
    \\--fsync-fail-step <u32>  Inject intent fsync failure before step 1-20.
    \\--short-write-step <u32>  Inject a torn intent before step 1-20.
    \\--exit-after-plan  Exit when execution stops (requires --execute --no-ui).
    \\--headless  Use the WPE headless display.
    \\--no-ui  Keep the business backend running without loading WPE.
    \\--tui  Require a libvaxis dashboard on the controlling terminal (default: auto).
    \\--no-tui  Keep line-oriented console output instead of a terminal dashboard.
    \\--tui-self-test  Draw and verify a real libvaxis terminal frame, then exit.
    \\--self-test  Exit after the real panel completes its bridge handshake.
    \\--timeout <u32>  Self-test timeout in seconds (default: 30).
    \\--test-exit  Exit unsuccessfully without loading WPE (VM supervisor fixture).
);

pub fn main(init: std.process.Init) !u8 {
    if (std.os.linux.getpid() == 1) return error.ApplicationMustNotBePid1;
    return run(init) catch |err| {
        std.log.err("Maintenance application: {t}", .{err});
        return 1;
    };
}
fn run(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    var parsed = try clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{ .allocator = a });
    defer parsed.deinit();
    if (parsed.args.help != 0) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Usage: pizza-maint [options]\n");
        try clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{});
        return 0;
    }
    var request: ?session.Request = null;
    if (parsed.args.session != 0) {
        if (parsed.args.execute != 0 or parsed.args.plan != null or parsed.args.journal != null or parsed.args.@"journal-home" != null or parsed.args.@"self-test" != 0 or parsed.args.@"test-exit" != 0 or parsed.args.@"step-fail" != null or parsed.args.@"step-hang" != null or parsed.args.@"fsync-fail-step" != null or parsed.args.@"short-write-step" != null) return error.SessionConflictsWithOverrides;
        var protected = try session.storage.openTrusted(init.io, "/etc/pizza");
        defer protected.close(init.io);
        try session.storage.trustedFile(init.io, protected, "session.json");
        try session.storage.trustedFile(init.io, protected, "plan.json");
        request = try std.json.parseFromSliceLeaky(session.Request, a, try protected.readFileAlloc(init.io, "session.json", a, .limited(16 * 1024)), .{});
        try request.?.validate();
        const bytes = try protected.readFileAlloc(init.io, "plan.json", a, .limited(1024 * 1024));
        if (!std.mem.eql(u8, request.?.plan_sha256, try session.digest(a, bytes))) return error.HandoffPlanChanged;
    }
    const no_ui = parsed.args.@"no-ui" != 0 or (if (request) |r| r.no_ui else false);
    const exit_after_plan = parsed.args.@"exit-after-plan" != 0 or (if (request) |r| r.test_poweroff else false);
    if (parsed.args.@"test-exit" != 0) return 17;
    if (parsed.args.tui != 0 and parsed.args.@"no-tui" != 0) return error.ConflictingTerminalOptions;
    if (parsed.args.@"tui-self-test" != 0 and (parsed.args.execute != 0 or parsed.args.@"self-test" != 0 or parsed.args.@"no-tui" != 0)) return error.ConflictingSelfTests;
    const force_tui = parsed.args.tui != 0 or parsed.args.@"tui-self-test" != 0;
    const dashboard = if (parsed.args.@"no-tui" == 0 and (parsed.args.@"self-test" == 0 or force_tui)) tui.Dashboard.open(a, init.io, init.environ_map, force_tui) catch |err| blk: {
        if (force_tui) return err;
        std.log.warn("Terminal dashboard unavailable: {t}; using console lines", .{err});
        break :blk null;
    } else null;
    defer if (dashboard) |value| value.close();
    if (parsed.args.@"tui-self-test" != 0) {
        const value = dashboard orelse return error.NoInteractiveTerminal;
        try value.selfTest();
        value.close();
        try std.Io.File.stdout().writeStreamingAll(init.io, "{\"libvaxis\":true,\"frame_verified\":true,\"progress\":\"7/20\"}\n");
        return 0;
    }
    if (parsed.args.@"self-test" != 0 and parsed.args.@"no-ui" != 0) return error.SelfTestNeedsWebView;
    const executing = parsed.args.execute != 0 or request != null;
    if (exit_after_plan and !no_ui) return error.ExitAfterPlanNeedsConsole;
    const execution_options: plan_module.Options = .{ .console = dashboard == null, .delay_ms = parsed.args.@"step-delay-ms" orelse 250, .fail_step = parsed.args.@"step-fail", .hang_step = parsed.args.@"step-hang", .fsync_fail_step = parsed.args.@"fsync-fail-step", .short_write_step = parsed.args.@"short-write-step" };
    try execution_options.validate();
    if (!executing and (parsed.args.@"journal-home" != null or parsed.args.@"step-delay-ms" != null or parsed.args.@"step-fail" != null or parsed.args.@"step-hang" != null or parsed.args.@"fsync-fail-step" != null or parsed.args.@"short-write-step" != null or parsed.args.@"exit-after-plan" != 0)) return error.ExecutionOptionNeedsExecute;
    if (executing and parsed.args.journal != null) return error.ExecutionConflictsWithReadOnlyJournal;
    var plan: ?proto.Plan = null;
    if (parsed.args.plan orelse if (request != null) @as(?[]const u8, session.plan_path) else null) |path| {
        plan = try std.json.parseFromSliceLeaky(proto.Plan, a, try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(1024 * 1024)), .{});
        try bridge.validatePlan(plan.?);
    }
    if (request) |r| if (plan == null or !std.mem.eql(u8, r.plan_id, plan.?.id)) return error.HandoffPlanMismatch;
    var persistent: ?session.storage.Mounted = null;
    defer if (persistent) |*home| {
        if (home.marker.status == .running) home.mark(a, init.io, .interrupted) catch |err| std.log.err("Session finalization: {t}", .{err});
        home.close(init.io);
    };
    if (request) |r| persistent = try session.storage.mount(a, init.io, r);
    var journal_path = parsed.args.journal;
    var executor: ?*plan_module.Executor = null;
    defer if (executor) |value| value.close(init.io);
    if (executing) {
        const actual_plan = plan orelse return error.MissingExecutionPlan;
        const home = try std.Io.Dir.cwd().realPathFileAlloc(init.io, (if (persistent) |home| home.path else parsed.args.@"journal-home" orelse return error.MissingJournalHome), a);
        var directory = try std.Io.Dir.cwd().openDir(init.io, home, .{ .follow_symlinks = false });
        defer directory.close(init.io);
        const kind = try @import("utils").filesystem.filesystemType(directory);
        if (kind != 0xef53 and kind != 0x58465342 and kind != 0x9123683e) return error.JournalHomeMustBePersistent;
        const anchor = try journal.captureBoundary(a, init.io, .{ .state = .start, .boot_id = "", .utc_unix_ns = "", .plan_id = actual_plan.id, .home = .{ .kind = .other_device, .path = home, .device_uuid = if (request) |r| r.home.uuid else null, .device_path = if (request) |r| r.home.path else null } });
        const value = try a.create(plan_module.Executor);
        value.* = try plan_module.Executor.start(a, init.io, directory, actual_plan, anchor.boundary, anchor.monotonic_ns, execution_options);
        executor = value;
        journal_path = try std.fs.path.join(a, &.{ home, "journal.bin" });
    }
    var fixture: ?[]const u8 = null;
    defer if (fixture) |path| std.Io.Dir.cwd().deleteTree(init.io, path) catch {};
    if (parsed.args.@"self-test" != 0 and journal_path == null and !executing) {
        fixture = try @import("utils").filesystem.createTemporaryDirectory(a, init.io, "pizza-bridge-fixture-");
        var directory = try std.Io.Dir.cwd().openDir(init.io, fixture.?, .{});
        defer directory.close(init.io);
        const steps = try a.alloc(proto.wire.Step, 20);
        for (steps, 0..) |*step, index| step.* = .{ .id = @intCast(index + 1), .label = "Bridge diagnostic", .simulated = true };
        plan = .{ .id = "bridge_selftest", .version = proto.api_version, .steps = steps };
        const anchor = try journal.captureBoundary(a, init.io, .{ .state = .start, .boot_id = "", .utc_unix_ns = "", .plan_id = plan.?.id, .home = .{ .kind = .root_path, .path = fixture.? } });
        var writer = try journal.Writer.create(a, init.io, directory, anchor.boundary, anchor.monotonic_ns, .{});
        defer writer.close(init.io);
        _ = try writer.intent(init.io, 1, try journal.monotonicNow(init.io), "bridge fixture intent");
        _ = try writer.commit(init.io, 1, try journal.monotonicNow(init.io), "bridge fixture commit");
        _ = try writer.intent(init.io, 2, try journal.monotonicNow(init.io), "unfinished fixture step");
        for (0..130) |_| _ = try writer.note(init.io, 2, try journal.monotonicNow(init.io), "native replay fixture");
        journal_path = try std.fs.path.join(a, &.{ fixture.?, "journal.bin" });
    }
    var backend = bridge.Backend.init(a, plan, journal_path);
    backend.executor = executor;
    if (persistent) |*home| backend.journal_home = home;
    backend.dashboard = dashboard;
    defer backend.deinit();
    try backend.refresh(init.io);
    if (parsed.args.headless != 0) {
        for ([_][2][:0]const u8{
            .{ "WPE_PLATFORM", "headless" },
            .{ "WPE_DISPLAY", "wpe-display-headless" },
            .{ "EGL_PLATFORM", "surfaceless" },
            .{ "LIBGL_ALWAYS_SOFTWARE", "true" },
            .{ "WEBKIT_SKIA_ENABLE_CPU_RENDERING", "1" },
        }) |entry| if (setenv(entry[0], entry[1], 1) != 0) return error.DisplayEnvironmentFailed;
    }
    // Explicit bundle-local paths for resources loaded dynamically by GLib/WPE.
    const cwd = try std.process.currentPathAlloc(init.io, a);
    for ([_][2][]const u8{
        .{ "WEBKIT_INJECTED_BUNDLE_PATH", "lib/wpe-webkit-2.0/injected-bundle" },
        .{ "WEBKIT_INSPECTOR_RESOURCES_PATH", "share/wpe-webkit-2.0" },
        .{ "GSETTINGS_SCHEMA_DIR", "share/glib-2.0/schemas" },
        .{ "GIO_EXTRA_MODULES", "lib/gio/modules" },
        .{ "GST_PLUGIN_SYSTEM_PATH_1_0", "lib/gstreamer-1.0" },
        .{ "FONTCONFIG_FILE", "share/fonts/fonts.conf" },
        .{ "__EGL_VENDOR_LIBRARY_FILENAMES", "share/glvnd/egl_vendor.d/50_mesa.json" },
        .{ "GBM_BACKENDS_PATH", "lib/gbm" },
        .{ "LIBGL_DRIVERS_PATH", "lib/dri" },
        .{ "XDG_DATA_DIRS", "share" },
    }) |entry| {
        const path = try std.fs.path.join(a, &.{ cwd, entry[1] });
        if (std.Io.Dir.cwd().access(init.io, path, .{})) {
            if (setenv(try a.dupeSentinel(u8, entry[0], 0), try a.dupeSentinel(u8, path, 0), 1) != 0) return error.ResourceEnvironmentFailed;
        } else |_| {}
    }
    if (!no_ui) {
        gui.run(a, init.io, &backend, .{
            .library = parsed.args.@"wpe-library" orelse "lib/libWPEWebKit-2.0.so.1",
            .panel = parsed.args.panel orelse "share/panel/index.html",
            .self_test = parsed.args.@"self-test" != 0,
            .timeout_s = parsed.args.timeout orelse 30,
        }) catch |err| {
            if (parsed.args.@"self-test" != 0) return err;
            std.log.err("Kiosk unavailable: {t}; business backend remains running", .{err});
        };
        if (backend.cancelled) return 130;
        if (parsed.args.@"self-test" != 0) {
            try std.Io.File.stdout().writeStreamingAll(init.io, try std.json.Stringify.valueAlloc(a, .{ .native_bridge = true, .journal_replay = true, .execution = backend.execution(), .last_seq = try a.print("{d}", .{backend.lastSequence()}), .pid = std.os.linux.getpid() }, .{ .whitespace = .indent_2 }));
            return if (executor) |value| (if (value.status == .succeeded) @as(u8, 0) else 1) else 0;
        }
    }
    std.log.info("PIZZA_MAINT_BACKEND_READY: execute={}", .{executing});
    while (true) {
        backend.tick(init.io) catch |err| if (err != error.WouldBlock) std.log.err("Journal view: {t}", .{err});
        if (backend.cancelled) return 130;
        if (exit_after_plan and executor.?.terminal()) return if (executor.?.status == .succeeded) 0 else 1;
        try std.Io.sleep(init.io, .fromMilliseconds(if (executing) 10 else if (backend.dashboard != null) 50 else 1000), .awake);
    }
}
