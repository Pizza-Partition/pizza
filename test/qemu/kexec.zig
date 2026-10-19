//! Actual systemd -> kexec_file_load -> production PID1/application -> recovery.
const std = @import("std");
const utils = @import("utils");
const initramfs = @import("initramfs");
const journal = @import("journal");
const clap = @import("clap");
const h = @import("harness.zig");
const params = clap.parseParamsComptime(
    \\-h, --help  Display help.
    \\--fixture <str>  Static first-boot fixture (supplied by build).
    \\--binary <str>  Actual pizza CLI (supplied by build).
    \\--bundle <str>  Prepared current full bundle (default: zig-out/runtime/bundle).
    \\--maintenance-image <str>  Reuse an already built maintenance image and metadata.
    \\--kernel-version <str>  Installed matching kernel release (required).
    \\--output <str>  Output directory outside checkout.
    \\--timeout <u32>  Timeout per boot, seconds (default: 300).
);
const Files = struct {
    a: std.mem.Allocator,
    io: std.Io,
    entries: std.ArrayList(initramfs.Entry) = .empty,
    names: std.StringHashMap(void),
    fn directory(self: *Files, name: []const u8) !void {
        if (name.len == 0 or self.names.contains(name)) return;
        if (std.fs.path.dirname(name)) |parent| try self.directory(parent);
        try self.names.put(name, {});
        try self.entries.append(self.a, .{ .name = name, .mode = 0o040755 });
    }
    fn bytes(self: *Files, name: []const u8, data: []const u8, executable: bool) !void {
        if (self.names.contains(name)) return;
        if (std.fs.path.dirname(name)) |parent| try self.directory(parent);
        try self.names.put(name, {});
        try self.entries.append(self.a, .{ .name = name, .mode = if (executable) 0o100755 else 0o100600, .data = data });
    }
    fn copy(self: *Files, source: []const u8, target: []const u8, executable: bool) !void {
        try self.bytes(target, try std.Io.Dir.cwd().readFileAlloc(self.io, source, self.a, .limited(512 * 1024 * 1024)), executable);
    }
    fn library(self: *Files, bundle: []const u8, name: []const u8) !void {
        const target = try self.a.print("usr/lib/{s}", .{name});
        if (self.names.contains(target)) return;
        const source = try std.fs.path.join(self.a, &.{ bundle, "lib", name });
        try self.copy(source, target, true);
        const metadata = try utils.elf.metadata(self.a, self.io, source);
        for (metadata.needed) |needed| try self.library(bundle, needed);
    }
};
pub fn run(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, checkout: []const u8, argv: []const []const u8) !void {
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var parsed = try clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{ .allocator = a });
    defer parsed.deinit();
    if (parsed.args.help != 0) return clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    const fixture = parsed.args.fixture orelse return error.MissingFixture;
    const binary = parsed.args.binary orelse return error.MissingBinary;
    const version = parsed.args.@"kernel-version" orelse return error.MissingKernelVersion;
    try utils.filesystem.checkPath(version);
    if (std.mem.indexOfScalar(u8, version, '/') != null) return error.InvalidKernelVersion;
    const bundle = parsed.args.bundle orelse "zig-out/runtime/bundle";
    const output = if (parsed.args.output) |p| try utils.filesystem.resolveOutputPath(a, io, checkout, p) else try utils.filesystem.createTemporaryDirectory(a, io, "pizza-qemu-kexec-");
    if (utils.filesystem.pathIsWithin(checkout, output)) return error.VmArtifactsMustBeOutsideCheckout;
    for (output) |c| if (std.ascii.isWhitespace(c) or c == ';' or c == '"' or c == '\\') return error.UnsupportedArtifactPath;
    try std.Io.Dir.cwd().createDirPath(io, output);
    const kernel = try a.print("/lib/modules/{s}/vmlinuz", .{version});
    const maintenance = parsed.args.@"maintenance-image" orelse try a.print("{s}/maintenance.img", .{output});
    if (parsed.args.@"maintenance-image" == null) _ = try initramfs.build(a, io, env, checkout, .{ .bundle = bundle, .output = maintenance, .kernel_version = version, .drivers = "virtio_pci virtio_blk ext4" });
    var files: Files = .{ .a = a, .io = io, .names = .init(a) };
    try files.copy(fixture, "init", true);
    try files.copy(fixture, "fixture", true);
    try files.copy(fixture, "fake/systemctl", true);
    try files.copy(binary, "pizza", true);
    try files.copy(kernel, "kernel", false);
    try files.copy(maintenance, "maintenance.img", false);
    try files.copy(try a.print("{s}.pizza.json", .{maintenance}), "maintenance.img.pizza.json", false);
    for ([_][]const u8{ "usr/lib/systemd/systemd", "usr/lib/systemd/systemd-shutdown", "usr/lib/systemd/systemd-executor", "usr/bin/systemctl" }) |name| try files.copy(try a.print("/{s}", .{name}), name, true);
    const systemd_meta = try utils.elf.metadata(a, io, "/usr/lib/systemd/systemd");
    for (systemd_meta.needed) |name| if (std.mem.startsWith(u8, name, "libsystemd-")) {
        try files.copy(try a.print("/usr/lib/systemd/{s}", .{name}), try a.print("usr/lib/systemd/{s}", .{name}), true);
    };
    // Systemd comes from this host fixture. Use the audited baseline glibc so
    // the fixture does not accidentally require the build host's x86-64-v4 libc.
    for ([_][2][]const u8{ .{ "lib/libc.so.6", "usr/lib/libc.so.6" }, .{ "lib/libm.so.6", "usr/lib/libm.so.6" }, .{ "lib/libgcc_s.so.1", "usr/lib/libgcc_s.so.1" }, .{ "lib/ld-linux-x86-64.so.2", "lib64/ld-linux-x86-64.so.2" } }) |pair| try files.copy(try std.fs.path.join(a, &.{ bundle, pair[0] }), pair[1], true);
    for ([_][]const u8{ "libcap.so.2", "libseccomp.so.2", "libmount.so.1", "libblkid.so.1", "libkmod.so.2", "libzstd.so.1", "liblzma.so.5", "liblz4.so.1", "libcrypto.so.3" }) |name| {
        const source = try std.fs.path.join(a, &.{ bundle, "lib", name });
        if (std.Io.Dir.cwd().access(io, source, .{})) try files.library(bundle, name) else |_| {}
    }
    try files.directory("usr/lib/systemd/system");
    try files.bytes("etc/passwd", "root:x:0:0:root:/root:/bin/sh\n", false);
    try files.bytes("etc/group", "root:x:0:\n", false);
    for ([_][]const u8{ "systemd-kexec.service", "kexec.target", "shutdown.target", "final.target", "umount.target" }) |name| try files.copy(try a.print("/usr/lib/systemd/system/{s}", .{name}), try a.print("etc/systemd/system/{s}", .{name}), false);
    try files.bytes("etc/systemd/system/pizza-test.target", "[Unit]\nDescription=Pizza isolated kexec acceptance\nDefaultDependencies=no\nRequires=pizza-test.service\nAfter=pizza-test.service\n", false);
    try files.bytes("etc/systemd/system/pizza-test.service", "[Unit]\nDescription=Production transition CLI fixture\nDefaultDependencies=no\nConflicts=shutdown.target\nBefore=shutdown.target\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/fixture run\nStandardOutput=append:/dev/console\nStandardError=append:/dev/console\nTimeoutStartSec=240\n", false);
    try files.bytes("etc/machine-id", "107f729b4a424a41b4c947c1b7ff9ac0\n", false);
    try files.bytes("etc/os-release", "ID=pizza-kexec-fixture\nNAME=Pizza VM fixture\n", false);
    try files.directory("dev");
    try files.entries.append(a, .{ .name = "dev/console", .mode = 0o020600, .device_major = 5, .device_minor = 1 });
    const first = try a.print("{s}/first.img", .{output});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = first, .data = try initramfs.archive(a, files.entries.items) });
    const original = try a.print("{s}/original.raw", .{output});
    const disk = try a.print("{s}/journal.raw", .{output});
    for ([_][]const u8{ original, disk }) |path| {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
        try file.setLength(io, 64 * 1024 * 1024);
        file.close(io);
        _ = try utils.process.checkedOutput(a, io, env, &.{ "mkfs.ext4", "-q", "-F", "-m", "0", path });
    }
    const before = try utils.filesystem.hashFileSha256(a, io, original);
    for ([_][]const u8{ "deny", "switch", "report" }, 0..) |name, index| {
        const directory = try a.print("{s}/{s}", .{ output, name });
        try std.Io.Dir.cwd().createDirPath(io, directory);
        var command = try h.baseCommand(a, io, env, directory, 4096);
        try command.appendSlice(&.{ "-nic", "none", "-kernel", kernel, "-initrd", first, "-append", if (index == 0) "console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.kexec_fixture=1 pizza.kexec_deny=1" else if (index == 1) "console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.kexec_fixture=1" else "console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.kexec_fixture=1 pizza.kexec_report=1", "-drive", try a.print("if=virtio,format=raw,readonly=on,file={s}", .{original}), "-drive", try a.print("if=virtio,format=raw,file={s}", .{disk}), "-no-reboot" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try a.print("{s}/command.json", .{directory}), .data = try std.json.Stringify.valueAlloc(a, command.items, .{ .whitespace = .indent_2 }) });
        const serial = try h.runVm(a, io, env, command.items, directory, parsed.args.timeout orelse 300);
        if (std.mem.indexOf(u8, serial, "PIZZA_KEXEC_TEST_FAILED") != null or std.mem.indexOf(u8, serial, "Kernel panic") != null) return error.KexecFixtureFailed;
        const expected: []const []const u8 = if (index == 0) &.{"PIZZA_KEXEC_DENIED_READY"} else if (index == 1) &.{ "PIZZA_KEXEC_ROLLBACK_READY", "PIZZA_KEXEC_FIRST_BOOT", "PIZZA_TRANSITION_LOADED", "PIZZA_JOURNAL_HOME_READY", "PIZZA_PLAN_STATE succeeded committed=20/20", "PIZZA_TRANSITION_MAINTENANCE_READY" } else &.{"PIZZA_KEXEC_RECOVERY_READY"};
        for (expected) |marker| if (std.mem.indexOf(u8, serial, marker) == null) return error.MissingKexecEvidence;
        if (index == 1 and (std.mem.indexOf(u8, serial, "Unable to finalize remaining file systems") != null or std.mem.indexOf(u8, serial, "Rebooting with kexec.") == null or std.mem.indexOf(u8, serial, "All filesystems unmounted.") == null)) return error.OrderlyShutdownIncomplete;
    }
    if (!std.mem.eql(u8, before, try utils.filesystem.hashFileSha256(a, io, original))) return error.OriginalDiskChanged;
    const extracted = try a.print("{s}/journal.bin", .{output});
    _ = try utils.process.checkedOutput(a, io, env, &.{ "debugfs", "-R", try a.print("dump /pizza-session/journal.bin {s}", .{extracted}), disk });
    const recovered = try journal.readFile(a, io, extracted);
    if (!recovered.state.complete or recovered.state.seq != 42) return error.BadRecoveredJournal;
    for ([_][2][]const u8{ .{ "transition.json", "transition-marker.json" }, .{ "plan.json", "durable-plan.json" } }) |pair| {
        _ = try utils.process.checkedOutput(a, io, env, &.{ "debugfs", "-R", try a.print("dump /pizza-session/{s} {s}/{s}", .{ pair[0], output, pair[1] }), disk });
    }
    const report = try utils.process.checkedOutput(a, io, env, &.{ binary, "transition", "report", "--journal", extracted });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try a.print("{s}/report.json", .{output}), .data = report });
    const json = try std.json.Stringify.valueAlloc(a, .{ .systemd_kexec = true, .load_permission_refusal = true, .shutdown_failure_rollback = true, .new_boot_identity = true, .production_session = true, .persistent_journal = true, .twenty_commits = true, .original_disk_unchanged = true, .post_reboot_report = true, .artifacts = output }, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try a.print("{s}/results.json", .{output}), .data = json });
    try std.Io.File.stdout().writeStreamingAll(io, json);
}
