//! Full bundle, live WPE execution and five persisted fault outcomes across boots.
const std = @import("std");
const utils = @import("utils");
const initramfs = @import("initramfs");
const journal = @import("journal");
const clap = @import("clap");
const h = @import("harness.zig");
const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--fixture <str>  Static executor fixture PID 1 (supplied by zig build).
    \\--report-binary <str>  Actual pizza CLI (supplied by zig build).
    \\--bundle <str>  Current prepared full bundle (default: zig-out/runtime/bundle).
    \\--kernel-version <str>  Matching installed kernel with built-in virtio/ext4.
    \\--kernel <str>  Kernel path (default: /lib/modules/VERSION/vmlinuz).
    \\--output <str>  New output directory outside the checkout.
    \\--timeout <u32>  Timeout per boot in seconds (default: 180).
);
pub fn run(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, checkout: []const u8, argv: []const []const u8) !void {
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var parsed = try clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{ .allocator = a });
    defer parsed.deinit();
    if (parsed.args.help != 0) return clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    const fixture = parsed.args.fixture orelse return error.MissingExecutorFixture;
    const report = parsed.args.@"report-binary" orelse return error.MissingReportBinary;
    const version = parsed.args.@"kernel-version" orelse return error.MissingKernelVersion;
    try utils.filesystem.checkPath(version);
    if (std.mem.indexOfScalar(u8, version, '/') != null) return error.InvalidKernelVersion;
    const meta = try utils.elf.metadata(a, io, fixture);
    if (meta.interp.len != 0 or meta.needed.len != 0) return error.Pid1MustBeStatic;
    const kernel = try utils.filesystem.resolveOutputPath(a, io, checkout, parsed.args.kernel orelse try a.print("/lib/modules/{s}/vmlinuz", .{version}));
    const output = if (parsed.args.output) |p| try utils.filesystem.resolveOutputPath(a, io, checkout, p) else try utils.filesystem.createTemporaryDirectory(a, io, "pizza-qemu-executor-");
    if (utils.filesystem.pathIsWithin(checkout, output)) return error.VmArtifactsMustBeOutsideCheckout;
    // debugfs -R has its own command grammar.
    for (output) |c| if (std.ascii.isWhitespace(c) or c == '"' or c == '\\' or c == ';') return error.DebugfsPathUnsupported;
    try std.Io.Dir.cwd().createDirPath(io, output);
    const base = try std.fs.path.join(a, &.{ output, "bundle.cpio.gz" });
    _ = try initramfs.build(a, io, env, checkout, .{ .bundle = parsed.args.bundle orelse "zig-out/runtime/bundle", .output = base, .kernel_version = version, .drivers = "virtio_pci virtio_blk ext4" });
    const overlay = try std.fs.path.join(a, &.{ output, "fixture.cpio.gz" });
    try initramfs.staticInit(a, io, fixture, overlay);
    const image = try std.fs.path.join(a, &.{ output, "executor.cpio.gz" });
    try std.Io.Dir.cwd().copyFile(base, .cwd(), image, io, .{});
    {
        const file = try std.Io.Dir.cwd().openFile(io, image, .{ .mode = .read_write });
        defer file.close(io);
        try file.writePositionalAll(io, try std.Io.Dir.cwd().readFileAlloc(io, overlay, a, .limited(32 * 1024 * 1024)), (try file.stat(io)).size);
    }
    const disk = try std.fs.path.join(a, &.{ output, "journal.raw" });
    try h.noComma(disk);
    {
        const file = try std.Io.Dir.cwd().createFile(io, disk, .{ .exclusive = true });
        defer file.close(io);
        try file.setLength(io, 64 * 1024 * 1024);
    }
    _ = try utils.process.checkedOutput(a, io, env, &.{ "mkfs.ext4", "-q", "-F", "-m", "0", disk });
    var serials: [2][]const u8 = undefined;
    for ([_][]const u8{ "write", "read" }, 0..) |mode, index| {
        const directory = try std.fs.path.join(a, &.{ output, mode });
        try std.Io.Dir.cwd().createDirPath(io, directory);
        var command = try h.baseCommand(a, io, env, directory, 4096);
        try command.appendSlice(&.{ "-nic", "none", "-kernel", kernel, "-initrd", image, "-append", try a.print("console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.executor_test={s}", .{mode}), "-drive", try a.print("if=virtio,format=raw,file={s}", .{disk}), "-no-reboot" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ directory, "command.json" }), .data = try std.json.Stringify.valueAlloc(a, command.items, .{ .whitespace = .indent_2 }) });
        const serial = try h.runVm(a, io, env, command.items, directory, parsed.args.timeout orelse 180);
        serials[index] = serial;
        if (!has(serial, try a.print("PIZZA_EXECUTOR_READY: {s}", .{mode})) or !has(serial, "PIZZA_EXECUTOR_UNMOUNTED") or !has(serial, "Power down") or has(serial, "PIZZA_EXECUTOR_TEST_FAILED") or has(serial, "Kernel panic")) return error.ExecutorBootFailed;
    }
    if (!has(serials[0], "PIZZA_BRIDGE_SELFTEST_READY") or !has(serials[0], "PIZZA_EXECUTOR_DOM_READY: progress=20; state=succeeded") or !has(serials[0], "PIZZA_EXECUTOR_DOM_READY: progress=7; state=degraded") or !has(serials[0], "PIZZA_PLAN_STATE succeeded committed=20/20")) return error.LiveExecutionBridgeFailed;
    // The previous case's completion delimits this worker's console output.
    const fsync_start = std.mem.indexOf(u8, serials[0], "PIZZA_EXECUTOR_CASE_READY: hang;") orelse return error.MissingFaultEvidence;
    const fsync_end = std.mem.indexOf(u8, serials[0], "PIZZA_EXECUTOR_CASE_READY: fsync;") orelse return error.MissingFaultEvidence;
    if (fsync_start >= fsync_end) return error.MissingFaultEvidence;
    const fsync_console = serials[0][fsync_start..fsync_end];
    if (!has(fsync_console, "PIZZA_PLAN_STATE degraded committed=7/20") or has(fsync_console, "PIZZA_PLAN_EVENT 8/20 intent")) return error.WorkStartedWithoutDurableIntent;
    const names = [_][]const u8{ "success", "failure", "hang", "fsync", "short" };
    for (names, 0..) |name, index| {
        const extracted = try a.print("{s}/{s}.journal.bin", .{ output, name });
        _ = try utils.process.checkedOutput(a, io, env, &.{ "debugfs", "-R", try a.print("dump /{s}/journal.bin {s}", .{ name, extracted }), disk });
        const value = try journal.readFile(a, io, extracted);
        if (index == 0) {
            if (!value.state.complete or value.state.seq != 42) return error.BadSuccess;
        } else if (index == 4) {
            if (value.tail != .short_header or value.state.seq != 15 or value.state.steps.contains(8)) return error.BadTornTail;
        } else {
            const expected: journal.StepState = if (index == 1) .failed else .in_flight;
            if (value.state.steps.get(8).?.state != expected or value.state.steps.contains(9)) return error.BadRecoveredStep;
        }
        const before = try utils.filesystem.hashFileSha256(a, io, extracted);
        const json = try utils.process.checkedOutput(a, io, env, &.{ report, "transition", "report", "--journal", extracted });
        _ = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try a.print("{s}/{s}.report.json", .{ output, name }), .data = json });
        if (!std.mem.eql(u8, before, try utils.filesystem.hashFileSha256(a, io, extracted))) return error.ReportChangedJournal;
    }
    const result = .{ .live_wpe_execution = true, .twenty_steps = true, .failure_stops = true, .hang_interrupted = true, .fsync_stops_before_work = true, .torn_tail = true, .two_boots = true, .no_automatic_retry = true, .read_only_report = true, .artifacts = output };
    const json = try std.json.Stringify.valueAlloc(a, result, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ output, "results.json" }), .data = json });
    try std.Io.File.stdout().writeStreamingAll(io, json);
}
fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}
