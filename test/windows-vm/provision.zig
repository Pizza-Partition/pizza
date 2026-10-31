//! Install only the configured, checksum-verified ISO into a newly owned disk.
const std = @import("std");
const clap = @import("clap");
const u = @import("vm_common");
const Vm = @import("vm.zig").Vm;
const lv = @import("libvirt.zig");
const config_api = @import("image_config.zig");
const digest = @import("fetch_image.zig").digest;
const PARAMS = clap.parseParamsComptime(
    \\-h, --help             Display help.
    \\--config <str>         Image configuration (default: test/windows-vm/images.json).
    \\--image <str>          Image ID (default: configured default).
    \\--iso <str>            ISO path (default: configured cache path).
    \\--stage <str>          Required: staged Windows artifacts directory.
    \\--drivers <str>        Required: directory containing vioscsi/vioscsi.inf, .sys, .cat.
    \\--out <str>            Required: new baseline directory.
    \\--resume               Resume an unfinished installation in --out; never reformat its OS disk.
    \\--code <str>           Pristine OVMF code (default: /usr/share/edk2/x64/OVMF_CODE.4m.fd).
    \\--vars <str>           Pristine OVMF vars (default: /usr/share/edk2/x64/OVMF_VARS.4m.fd).
    \\--index <index>        Windows install image index (default: 1).
    \\--timeout <seconds>    Installation deadline (default: 1800).
);
pub fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var iter: clap.args.SliceIterator = .{ .args = args[1..] };
    var parsed = try clap.parseEx(clap.Help, &PARAMS, .{ .str = clap.parsers.string, .index = clap.parsers.int(u16, 10), .seconds = clap.parsers.int(u32, 10) }, &iter, .{ .allocator = a });
    defer parsed.deinit();
    if (parsed.args.help != 0) return clap.helpToFile(io, .stdout(), clap.Help, &PARAMS, .{});
    const options = parsed.args;
    const cwd = try std.process.currentPathAlloc(io, a);
    const out = try std.fs.path.resolve(a, &.{ cwd, options.out orelse return error.OutputRequired });
    const stage = try std.fs.path.resolve(a, &.{ cwd, options.stage orelse return error.StageRequired });
    const drivers = try std.fs.path.resolve(a, &.{ cwd, options.drivers orelse return error.DriversRequired });
    const config = try config_api.Config.parse(a, try std.Io.Dir.cwd().readFileAlloc(io, options.config orelse "test/windows-vm/images.json", a, .limited(512 * 1024 * 1024)));
    const image = try config.select(options.image);
    const iso = try std.fs.path.resolve(a, &.{ cwd, options.iso orelse try std.fs.path.join(a, &.{ config.download.cache_dir, image.filename }) });
    for ([_][]const u8{ out, stage, iso }) |p| if (std.mem.indexOfAny(u8, p, "<>&\"'\r\n") != null) return error.UnsupportedPathCharacters;
    const seconds = options.timeout orelse 1800;
    if (seconds == 0 or seconds > 7200) return error.InvalidTimeout;
    const actual = try digest(io, iso);
    if (actual.size != image.size or !std.mem.eql(u8, &actual.sha256, image.sha256)) return error.ImageChecksumMismatch;
    const driver_bytes = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ drivers, "vioscsi/vioscsi.sys" }), a, .limited(512 * 1024 * 1024));
    if (driver_bytes.len < 64 or !std.mem.startsWith(u8, driver_bytes, "MZ")) return error.InvalidVirtioDriverBinary;
    const is_resume = options.@"resume" != 0;
    if (is_resume) {
        if (std.Io.Dir.cwd().statFile(io, try std.fs.path.join(a, &.{ out, "baseline.json" }), .{})) |_| return error.CannotResumeFrozenBaseline else |err| if (err != error.FileNotFound) return err;
        const source = try std.json.parseFromSliceLeaky(struct { image: struct { id: []const u8, sha256: []const u8 } }, a, try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ out, "source.json" }), a, .limited(512 * 1024 * 1024)), .{ .ignore_unknown_fields = true });
        if (!std.mem.eql(u8, source.image.id, image.id) or !std.mem.eql(u8, source.image.sha256, image.sha256)) return error.ResumeImageMismatch;
    } else try std.Io.Dir.cwd().createDir(io, out, .fromMode(0o700));
    var random: [6]u8 = undefined;
    io.random(&random);
    const token = try a.dupe(u8, &std.fmt.bytesToHex(random, .lower));
    var env = try init.environ_map.clone(a);
    _ = env.swapRemove("PIZZA_VM_PASSWORD");
    var v: Vm = .{ .a = a, .io = io, .env = env, .base = out, .stage = stage, .out = out, .user = "PizzaTest", .password = try a.alloc(u8, 0), .cases = "", .native = false, .transport = .agent, .timeout_ms = @as(i64, seconds) * 1000, .token = token, .serial = try a.print("PZ-E2E-{s}", .{token}), .wwn = try a.print("5001{s}", .{token}), .work = try a.print("C:\\Pizza-E2E-{s}", .{token}), .boot_id = try u.hostBootId(a, io) };
    defer v.deinit();
    errdefer v.failure(error.ProvisioningFailed);
    const code = try std.fs.path.join(a, &.{ out, "OVMF_CODE.fd" });
    const vars = try std.fs.path.join(a, &.{ out, "OVMF_VARS.fd" });
    const disk = try std.fs.path.join(a, &.{ out, "windows.raw" });
    const artifacts = try std.fs.path.join(a, &.{ out, "install.raw" });
    if (!is_resume) {
        try std.Io.Dir.cwd().copyFile(options.code orelse "/usr/share/edk2/x64/OVMF_CODE.4m.fd", .cwd(), code, io, .{});
        try std.Io.Dir.cwd().copyFile(options.vars orelse "/usr/share/edk2/x64/OVMF_VARS.4m.fd", .cwd(), vars, io, .{});
        _ = try u.check(try u.runAt(a, io, &v.env, .inherit, &.{ "qemu-img", "create", "-f", "raw", disk, "64G" }, null, 30));
    } else if ((try std.Io.Dir.cwd().statFile(io, disk, .{})).permissions.readOnly()) return error.CannotResumeFrozenBaseline;
    _ = try u.check(try u.runAt(a, io, &v.env, .inherit, &.{ "qemu-img", "create", "-f", "raw", artifacts, "256M" }, null, 30));
    _ = try u.check(try u.runAt(a, io, &v.env, .inherit, &.{ "mkfs.vfat", "-F", "32", "-n", "PIZZA_SETUP", artifacts }, null, 30));
    const answer = try std.mem.replaceOwned(u8, a, @embedFile("autounattend.xml"), "@INDEX@", try a.print("{d}", .{options.index orelse 1}));
    const answer_path = try std.fs.path.join(a, &.{ out, "autounattend.xml" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = answer_path, .data = answer });
    for ([_][]const u8{ "windows-vm-guest.exe", "pizza-backend.exe", "maint.efi", "windows-tests" }) |name| _ = try u.check(try u.runAt(a, io, &v.env, .inherit, &.{ "mcopy", "-s", "-i", artifacts, try std.fs.path.join(a, &.{ stage, name }), "::/" }, null, 60));
    _ = try u.check(try u.runAt(a, io, &v.env, .inherit, &.{ "mcopy", "-s", "-i", artifacts, try std.fs.path.join(a, &.{ drivers, "vioscsi" }), "::/" }, null, 60));
    _ = try u.check(try u.runAt(a, io, &v.env, .inherit, &.{ "mcopy", "-i", artifacts, answer_path, "::/autounattend.xml" }, null, 30));
    try v.startDaemon();
    const xml = try a.print("<domain type='kvm'><name>pizza-install-{s}</name><memory unit='MiB'>4096</memory><vcpu>4</vcpu>" ++
        "<os><type arch='x86_64' machine='q35'>hvm</type><loader readonly='yes' type='pflash'>{s}</loader><nvram>{s}</nvram></os>" ++
        "<features><acpi/><apic/><smm state='off'/></features><cpu mode='host-passthrough'/><clock offset='localtime'/>" ++
        "<on_poweroff>destroy</on_poweroff><on_reboot>restart</on_reboot><devices><emulator>/usr/bin/qemu-system-x86_64</emulator>" ++
        "<controller type='scsi' model='virtio-scsi'/><controller type='usb' model='qemu-xhci'/>" ++
        "<disk type='file' device='disk'><driver name='qemu' type='raw' cache='none'/><source file='{s}'/><target dev='sda' bus='sata'/><boot order='2'/></disk>" ++
        "<disk type='file' device='cdrom'><driver name='qemu' type='raw'/><source file='{s}'/><target dev='sdb' bus='sata'/><readonly/><boot order='1'/></disk>" ++
        "<disk type='file' device='disk'><driver name='qemu' type='raw'/><source file='{s}'/><target dev='sdc' bus='usb' removable='on'/></disk>" ++
        "<serial type='pty'><target type='isa-serial' port='0'/></serial><console type='pty'><target type='serial' port='0'/></console>" ++
        "<serial type='pty'><target type='isa-serial' port='1'/><alias name='serial1'/></serial>" ++
        "<video><model type='vga' heads='1' primary='yes'/></video><memballoon model='none'/></devices></domain>", .{ token, code, vars, disk, iso, artifacts });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ out, "install.xml" }), .data = xml });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ out, "source.json" }), .data = try std.json.Stringify.valueAlloc(a, .{ .image = image, .iso_sha256 = actual.sha256 }, .{ .whitespace = .indent_2 }) });
    try v.domain.?.start(xml);
    v.xml = xml;
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    var last_screen: i64 = 0;
    var last_key: i64 = 0;
    var ready = false;
    while (std.Io.Clock.awake.now(io).toMilliseconds() - started < v.timeout_ms) {
        var buf: [16384]u8 = undefined;
        const count = try v.domain.?.recvAgent(&buf);
        if (count > 0) {
            try v.transcript.append(a, buf[0..count]);
            if (v.transcript.contains(0, "PZ_AGENT_READY")) {
                ready = true;
                break;
            }
        }
        _ = try v.domain.?.recv(&buf);
        const now = std.Io.Clock.awake.now(io).toMilliseconds();
        // Dismiss the DVD's first-boot key prompt; later boots use the installed OS.
        if (!is_resume and now - started < 12000 and now - last_key > 1000) {
            var key: c_uint = 28; // Linux KEY_ENTER.
            try lv.checked(lv.c.virDomainSendKey(v.domain.?.domain, lv.c.VIR_KEYCODE_SET_LINUX, 100, &key, 1, 0));
            last_key = now;
        }
        if (now - last_screen > 10000) {
            try v.domain.?.screenshot(io, try std.fs.path.join(a, &.{ out, "install.ppm" }));
            std.debug.print("Windows installation: {d}s, state={d}\n", .{ @divTrunc(now - started, 1000), (try v.domain.?.state()).state });
            last_screen = now;
        }
        _ = lv.c.usleep(20000);
    }
    if (!ready) return error.InstallationTimeout;
    // Never allow a later serial byte to trigger the DVD's unattended setup.
    // The USB test artifacts stay mounted; the installation ISO is no longer needed.
    try v.domain.?.ejectInstaller();
    try v.guest("install", "accept");
    _ = try v.settleWindows();
    try v.guest("freeze", "accept");
    try v.restartWindows();
    const servicing = try v.settleWindows();
    if (!servicing.updates_disabled or servicing.reboot_pending or servicing.installer_running or servicing.update_services_running) return error.BaselineUpdatePolicyNotFrozen;
    try v.guest("probe", "accept");
    try v.collect();
    try v.guest("shutdown", "accept");
    const shutdown_deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 60000;
    while ((try v.domain.?.state()).state != lv.c.VIR_DOMAIN_SHUTOFF) {
        if (std.Io.Clock.awake.now(io).toMilliseconds() >= shutdown_deadline) return error.ShutdownTimeout;
        _ = lv.c.usleep(100000);
    }
    try v.domain.?.stop();
    for ([_][]const u8{ disk, code, vars }) |path| {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o444));
    }
    const capabilities = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ out, "guest/capabilities.json" }), a, .limited(512 * 1024 * 1024)), .{});
    if (!std.mem.eql(u8, v.boot_id, try u.hostBootId(a, io))) return error.HostRebooted;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ out, "baseline.json" }), .data = try std.json.Stringify.valueAlloc(a, .{ .version = @as(u32, 1), .image = image, .transport = "agent", .network = false, .host_boot_id = v.boot_id, .status = "ready", .updates_disabled = true, .servicing = servicing, .capabilities = capabilities, .guest_sha256 = (try digest(io, try std.fs.path.join(a, &.{ stage, "windows-vm-guest.exe" }))).sha256 }, .{ .whitespace = .indent_2 }) });
    std.debug.print("Frozen Windows baseline: {s}\n", .{out});
}
