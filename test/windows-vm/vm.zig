const std = @import("std");
const vm_common = @import("vm_common");
const lv = @import("libvirt.zig");
const sac = @import("sac.zig");
const agent = @import("agent_protocol.zig");
const hashFile = @import("fetch_image.zig").digest;
pub const cli = @import("cli.zig");
pub const provision = @import("provision.zig").run;
const c_api = lv.libvirt_c;
pub var context: *Vm = undefined;
const Result = struct { case: []const u8, outcome: []const u8, id: []const u8, hash: []const u8 };

pub const Vm = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: std.process.Environ.Map,
    base: []const u8,
    stage: []const u8,
    out: []const u8,
    user: []const u8,
    password: []u8,
    cases: []const u8,
    native: bool,
    transport: enum { sac, agent } = .sac,
    updates_frozen: bool = false,
    timeout_ms: i64,
    token: []const u8,
    serial: []const u8,
    wwn: []const u8,
    work: []const u8,
    boot_id: []const u8,
    xml: []const u8 = "",
    daemon: ?std.process.Child = null,
    daemon_log: ?std.Io.File = null,
    domain: ?lv.Domain = null,
    transcript: sac.Transcript = .{},
    logging: bool = true,
    last_health: i64 = 0,
    last_screen: i64 = 0,
    generation: u32 = 0,
    command_id: u32 = 0,
    last_guest_stdout: []const u8 = "",
    results: std.ArrayList(Result) = .empty,

    pub fn init(init_: std.process.Init, options: cli.Runner.Options) !Vm {
        const a = init_.arena.allocator();
        const cwd = try std.process.currentPathAlloc(init_.io, a);
        const base = try std.fs.path.resolve(a, &.{ cwd, options.base orelse return error.BaseRequired });
        const baseline_path = try std.fs.path.join(a, &.{ base, "baseline.json" });
        const baseline = std.Io.Dir.cwd().readFileAlloc(init_.io, baseline_path, a, .limited(512 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => "{}",
            else => return err,
        };
        const baseline_options = try std.json.parseFromSliceLeaky(struct { transport: []const u8 = "sac", updates_disabled: bool = false }, a, baseline, .{ .ignore_unknown_fields = true });
        const transport = std.meta.stringToEnum(@FieldType(Vm, "transport"), options.transport orelse baseline_options.transport) orelse return error.InvalidTransport;
        if (transport == .agent and !baseline_options.updates_disabled) return error.BaselineUpdatesNotFrozen;
        var env = try init_.environ_map.clone(a);
        const password = if (transport == .agent) try a.alloc(u8, 0) else if (env.get("PIZZA_VM_PASSWORD")) |p| try a.dupe(u8, p) else blk: {
            const p = c_api.getpass("Windows SAC password (not saved): ") orelse return error.PasswordRequired;
            const secret = try a.dupe(u8, std.mem.span(p));
            @memset(p[0..secret.len], 0);
            break :blk secret;
        };
        _ = env.swapRemove("PIZZA_VM_PASSWORD");
        if ((transport == .sac and password.len == 0) or std.mem.indexOfAny(u8, password, "\r\n") != null) return error.InvalidPassword;
        const user = options.user orelse "perdixky";
        for (user) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return error.InvalidUsername;
        const stage = try std.fs.path.resolve(a, &.{ cwd, options.stage orelse return error.StageRequired });
        const out = try std.fs.path.resolve(a, &.{ cwd, options.out orelse return error.OutputRequired });
        // Paths enter both XML and a CMD launch command. Fail rather than quote ambiguously.
        for ([_][]const u8{ base, stage, out }) |p| if (std.mem.indexOfAny(u8, p, "<>&\"'\r\n") != null) return error.UnsupportedPathCharacters;
        const seconds = options.timeout orelse 600;
        const native = options.native orelse .run;
        try vm_common.cases.validate(options.cases orelse vm_common.cases.csv);
        var random: [6]u8 = undefined;
        init_.io.random(&random);
        const token = try a.dupe(u8, &std.fmt.bytesToHex(random, .lower));
        try std.Io.Dir.cwd().createDir(init_.io, out, .fromMode(0o700));
        return .{ .a = a, .io = init_.io, .env = env, .base = base, .stage = stage, .out = out, .user = user, .password = password, .transport = transport, .cases = options.cases orelse vm_common.cases.csv, .native = native == .run, .timeout_ms = @as(i64, seconds) * 1000, .token = token, .serial = try a.print("PZ-E2E-{s}", .{token}), .wwn = try a.print("5001{s}", .{token}), .work = try a.print("C:\\Pizza-E2E-{s}", .{token}), .boot_id = try vm_common.hostBootId(a, init_.io) };
    }
    pub fn endTime(v: Vm) i64 {
        return v.now() + v.timeout_ms;
    }
    pub fn consoleMark(v: Vm) usize {
        return v.transcript.mark();
    }
    pub fn contains(v: Vm, start: usize, needle: []const u8) bool {
        return v.transcript.contains(start, needle);
    }
    pub fn send(v: *Vm, bytes: []const u8) !void {
        try v.domain.?.send(bytes);
    }
    pub fn now(v: Vm) i64 {
        return std.Io.Clock.awake.now(v.io).toMilliseconds();
    }
    fn path(v: Vm, name: []const u8) ![]const u8 {
        return std.fs.path.join(v.a, &.{ v.out, name });
    }
    fn append(v: Vm, name: []const u8, bytes: []const u8) !void {
        const f = try std.Io.Dir.cwd().createFile(v.io, try v.path(name), .{ .truncate = false });
        defer f.close(v.io);
        const st = try f.stat(v.io);
        try f.writePositionalAll(v.io, bytes, st.size);
    }
    fn save(v: Vm, name: []const u8, value: anytype) !void {
        try std.Io.Dir.cwd().writeFile(v.io, .{ .sub_path = try v.path(name), .data = try std.json.Stringify.valueAlloc(v.a, value, .{ .whitespace = .indent_2 }) });
    }
    fn event(v: Vm, phase: []const u8) !void {
        std.debug.print("[{d}] {s}\n", .{ v.generation, phase });
        try v.append("events.jsonl", try v.a.print("{s}\n", .{try std.json.Stringify.valueAlloc(v.a, .{ .ms = v.now(), .generation = v.generation, .phase = phase }, .{})}));
    }
    fn command(v: *Vm, argv: []const []const u8) !void {
        _ = try vm_common.check(try vm_common.runAt(v.a, v.io, &v.env, .inherit, argv, null, 600));
    }
    pub fn deinit(v: *Vm) void {
        if (v.domain) |*d| d.deinit();
        if (v.daemon) |*d| d.kill(v.io);
        if (v.daemon_log) |f| f.close(v.io);
        @memset(v.password, 0);
        v.env.deinit();
    }
    pub fn startDaemon(v: *Vm) !void {
        // A private rootless session keeps the user's other VMs out of scope.
        const runtime = try v.a.print("/tmp/pizza-libvirt-{s}", .{v.token});
        try std.Io.Dir.cwd().createDir(v.io, runtime, .fromMode(0o700));
        // libvirt also puts QMP probe sockets below this directory: keep it short.
        const conf = try std.fs.path.join(v.a, &.{ runtime, "config" });
        try std.Io.Dir.cwd().createDirPath(v.io, try std.fs.path.join(v.a, &.{ conf, "libvirt" }));
        try std.Io.Dir.cwd().writeFile(v.io, .{ .sub_path = try std.fs.path.join(v.a, &.{ conf, "libvirt/qemu.conf" }), .data = "stdio_handler = \"file\"\nsecurity_driver = \"none\"\n" });
        try v.env.put("XDG_RUNTIME_DIR", runtime);
        try v.env.put("XDG_CONFIG_HOME", conf);
        try v.env.put("XDG_CACHE_HOME", try v.path("cache"));
        v.daemon_log = try std.Io.Dir.cwd().createFile(v.io, try v.path("libvirtd.log"), .{});
        const prefix = @import("vm_options").libvirt_prefix;
        v.daemon = try std.process.spawn(v.io, .{ .argv = &.{ try std.fs.path.join(v.a, &.{ prefix, "sbin/libvirtd" }), "--timeout", "0" }, .environ_map = &v.env, .stdin = .ignore, .stdout = .{ .file = v.daemon_log.? }, .stderr = .{ .file = v.daemon_log.? } });
        const socket = try std.fs.path.join(v.a, &.{ runtime, "libvirt/libvirt-sock" });
        const until = v.now() + 15000;
        while (v.now() < until) {
            if (std.Io.Dir.cwd().statFile(v.io, socket, .{})) |_| break else |_| {}
            _ = c_api.usleep(20000);
        }
        v.domain = try lv.Domain.connect(v.a, try v.a.print("qemu+unix:///session?socket={s}", .{socket}));
    }
    pub fn startSuite(v: *Vm) !void {
        for ([_][]const u8{ "windows.raw", "OVMF_CODE.fd", "OVMF_VARS.fd" }) |name| {
            const st = try std.Io.Dir.cwd().statFile(v.io, try std.fs.path.join(v.a, &.{ v.base, name }), .{});
            if (!st.permissions.readOnly()) return error.ReadonlyBaselineRequired;
        }
        const vars = try v.path("OVMF_VARS.fd");
        try std.Io.Dir.cwd().writeFile(v.io, .{ .sub_path = vars, .data = try std.Io.Dir.cwd().readFileAlloc(v.io, try std.fs.path.join(v.a, &.{ v.base, "OVMF_VARS.fd" }), v.a, .limited(512 * 1024 * 1024)) });
        const system = try v.path("windows.qcow2");
        const target = try v.path("target.raw");
        const artifacts = try v.path("artifacts.raw");
        try v.command(&.{ "qemu-img", "create", "-f", "qcow2", "-F", "raw", "-b", try std.fs.path.join(v.a, &.{ v.base, "windows.raw" }), system });
        try v.command(&.{ "qemu-img", "create", "-f", "raw", target, "4G" });
        try v.command(&.{ "qemu-img", "create", "-f", "raw", artifacts, "256M" });
        try v.command(&.{ "mkfs.vfat", "-F", "32", "-n", "PIZZA_TESTS", artifacts });
        for ([_][]const u8{ "windows-vm-guest.exe", "pizza-backend.exe", "maint.efi", "windows-tests" }) |name|
            try v.command(&.{ "mcopy", "-s", "-i", artifacts, try std.fs.path.join(v.a, &.{ v.stage, name }), "::/" });
        const code = try std.fs.path.join(v.a, &.{ v.base, "OVMF_CODE.fd" });
        v.xml = try v.a.print("<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'><name>pizza-test-{s}</name><memory unit='MiB'>4096</memory><vcpu>2</vcpu>" ++
            "<os><type arch='x86_64' machine='q35'>hvm</type><loader readonly='yes' type='pflash'>{s}</loader><nvram>{s}</nvram></os>" ++
            "<features><acpi/><apic/><smm state='off'/></features><cpu mode='host-passthrough'/><clock offset='localtime'/>" ++
            "<on_poweroff>destroy</on_poweroff><on_reboot>restart</on_reboot><on_crash>preserve</on_crash><devices>" ++
            "<emulator>/usr/bin/qemu-system-x86_64</emulator><controller type='scsi' model='virtio-scsi'/><controller type='usb' model='qemu-xhci'/>" ++
            "<disk type='file' device='disk'><driver name='qemu' type='qcow2' cache='none'/><source file='{s}'/><target dev='sda' bus='scsi'/><alias name='ua-system'/></disk>" ++
            "<disk type='file' device='disk'><driver name='qemu' type='raw' cache='none'/><source file='{s}'/><target dev='sdb' bus='scsi'/><serial>{s}</serial><wwn>{s}</wwn></disk>" ++
            "<disk type='file' device='disk'><driver name='qemu' type='raw'/><source file='{s}'/><target dev='sdc' bus='usb' removable='on'/><readonly/></disk>" ++
            "<serial type='pty'><target type='isa-serial' port='0'/></serial><console type='pty'><target type='serial' port='0'/></console>" ++
            "<serial type='pty'><target type='isa-serial' port='1'/><alias name='serial1'/></serial>" ++
            "<video><model type='virtio' heads='1' primary='yes'/></video><memballoon model='none'/></devices>" ++
            // libvirt injects bootindex=1 even without an XML <boot> element.
            // OVMF treats that fw_cfg list as authoritative and deletes the
            // guest-created maintenance entry. Keep boot policy in NVRAM.
            "<qemu:override><qemu:device alias='ua-system'><qemu:frontend><qemu:property name='bootindex' type='remove'/></qemu:frontend></qemu:device></qemu:override>" ++
            // Select the test console through the firmware interface; never
            // rebuild or patch the published, digest-bound maintenance UKI.
            "<qemu:commandline><qemu:arg value='-smbios'/><qemu:arg value='type=11,value=io.systemd.stub.kernel-cmdline-extra=console=ttyS0'/></qemu:commandline></domain>", .{ v.token, code, vars, system, target, v.serial, v.wwn, artifacts });
        try std.Io.Dir.cwd().writeFile(v.io, .{ .sub_path = try v.path("domain.xml"), .data = v.xml });
        try v.save("inputs.json", .{
            .base = v.base,
            .stage = v.stage,
            .serial = v.serial,
            .wwn = v.wwn,
            .work = v.work,
            .host_boot_id = v.boot_id,
            .native = v.native,
            .cases = v.cases,
            .transport = @tagName(v.transport),
            .network = false,
            .executable_sha256 = (try hashFile(v.io, try std.fs.path.join(v.a, &.{ v.stage, "pizza-backend.exe" }))).sha256,
            .guest_sha256 = (try hashFile(v.io, try std.fs.path.join(v.a, &.{ v.stage, "windows-vm-guest.exe" }))).sha256,
            .image_sha256 = (try hashFile(v.io, try std.fs.path.join(v.a, &.{ v.stage, "maint.efi" }))).sha256,
            .firmware_code_sha256 = (try hashFile(v.io, code)).sha256,
            .firmware_vars_sha256 = (try hashFile(v.io, vars)).sha256,
        });
        try v.startDaemon();
        try v.boot();
        try v.login();
        if (v.transport == .agent) {
            const until = v.now() + v.timeout_ms;
            while (true) {
                v.guest("install", "accept") catch |err| {
                    // Explicitly no executable was found and nothing was run.
                    // Wait for Windows removable-media enumeration, never retry
                    // an uncertain or partially executed installation.
                    if (err != error.ArtifactsMissing or v.now() >= until) return err;
                    _ = c_api.usleep(500000);
                    continue;
                };
                break;
            }
        } else {
            const start = v.transcript.mark();
            const install = try v.a.print("for %d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %d:\\windows-vm-guest.exe %d:\\windows-vm-guest.exe install {s} {s} {s} accept", .{ v.work, v.serial, v.wwn });
            try v.shell(install, start);
        }
        if (v.transport == .agent) try v.requireFrozen();
        try v.guest("probe", "accept");
        if (v.native) try v.guest("native", "accept");
        try v.guest("setup", "accept");
    }
    pub fn boot(v: *Vm) !void {
        v.generation += 1;
        try v.domain.?.start(v.xml);
        try v.event("vm-started");
    }
    pub fn pump(v: *Vm) !void {
        var buf: [16384]u8 = undefined;
        const n = try v.domain.?.recv(&buf);
        if (n > 0) {
            try v.transcript.append(v.a, buf[0..n]);
            if (v.logging) try v.append("serial.log", buf[0..n]);
        }
        const count = try v.domain.?.recvAgent(&buf);
        if (count > 0) {
            try v.transcript.append(v.a, buf[0..count]);
            if (v.logging) try v.append("agent.log", buf[0..count]);
        }
        if (v.now() - v.last_health >= 2000) {
            const state = try v.domain.?.state();
            v.last_health = v.now();
            try v.append("health.jsonl", try v.a.print("{s}\n", .{try std.json.Stringify.valueAlloc(v.a, .{ .ms = v.now(), .generation = v.generation, .state = state.state, .reason = state.reason }, .{})}));
            if (state.state != c_api.VIR_DOMAIN_RUNNING and state.state != c_api.VIR_DOMAIN_BLOCKED) return error.GuestStopped;
            if (v.now() - v.last_screen >= 30000) {
                try v.domain.?.screenshot(v.io, try v.path("current.png"));
                v.last_screen = v.now();
            }
        }
        if (n == 0) _ = c_api.usleep(10000);
    }
    pub fn wait(v: *Vm, text: []const u8, start: usize) !void {
        const until = v.now() + v.timeout_ms;
        while (v.now() < until) {
            if (v.transcript.contains(start, text)) return;
            if (v.transcript.contains(start, "PIZZA_RESTART_FAILED") or v.transcript.contains(start, "PIZZA_MAINT_DEGRADED") or v.transcript.contains(start, "Kernel panic")) return error.MaintenanceFailed;
            try v.pump();
        }
        std.debug.print("Console timeout waiting for {s}\n", .{text});
        return error.ConsoleTimeout;
    }
    pub fn login(v: *Vm) !void {
        if (v.transport == .agent) {
            try v.event("waiting-for-zig-serial-agent");
            const start = v.transcript.mark();
            try v.wait("PZ_AGENT_READY", start);
            // Initial login precedes copying the test executable. On later
            // Windows boots wait for read-only storage queries before commands.
            if (v.command_id != 0 and v.updates_frozen) {
                try v.requireFrozen();
                try v.guest("probe", "accept");
            }
            return;
        }
        try v.event("waiting-for-sac");
        const start = v.transcript.mark();
        try v.domain.?.send("\r\n");
        try v.wait("SAC>", start);
        var mark = v.transcript.mark();
        try v.domain.?.send("cmd\r\n");
        try v.wait("Cmd0001", mark);
        mark = v.transcript.mark();
        try v.domain.?.send("ch -sn Cmd0001\r\n");
        // Never save authentication traffic, including an unexpectedly echoed password.
        v.logging = false;
        defer v.logging = true;
        try v.wait("Username:", mark);
        mark = v.transcript.mark();
        try v.domain.?.send(try v.a.print("{s}\r\n", .{v.user}));
        try v.wait("Domain", mark);
        mark = v.transcript.mark();
        try v.domain.?.send(".\r\n");
        try v.wait("Password", mark);
        mark = v.transcript.mark();
        try v.domain.?.send(try v.a.print("{s}\r\n", .{v.password}));
        try v.wait(">", mark);
        // Discard authentication bytes from memory before any diagnostics can export them.
        @memset(v.transcript.bytes.items[start..], 0);
        v.transcript.bytes.items.len = start;
        try v.event("sac-command-channel-ready");
    }
    fn shell(v: *Vm, command_: []const u8, start: usize) !void {
        v.command_id += 1;
        const marker = try v.a.print("PZ_{s}_{d}", .{ v.token, v.command_id });
        try v.domain.?.send(try v.a.print("{s} && echo {s}:OK || echo {s}:FAIL\r\n", .{ command_, marker, marker }));
        const until = v.now() + v.timeout_ms;
        while (v.now() < until) {
            if (try sac.result(v.transcript.since(start), marker)) |ok| {
                if (!ok) return error.GuestCommandFailed;
                return;
            }
            try v.pump();
        }
        return error.GuestCommandTimeout;
    }
    pub fn guest(v: *Vm, action: []const u8, case: []const u8) !void {
        try v.event(try v.a.print("{s}:{s}", .{ case, action }));
        const start = v.transcript.mark();
        if (v.transport == .agent) return v.agentCommand(action, case, start);
        const command_ = try v.a.print("{s}\\windows-vm-guest.exe {s} {s} {s} {s} {s}", .{ v.work, action, v.work, v.serial, v.wwn, case });
        if (std.mem.eql(u8, action, "reboot") or std.mem.eql(u8, action, "shutdown")) {
            try v.domain.?.send(try v.a.print("{s}\r\n", .{command_}));
            return;
        }
        try v.shell(command_, start);
    }
    fn agentCommand(v: *Vm, action: []const u8, case: []const u8, start: usize) !void {
        v.command_id += 1;
        const id = try v.a.print("PZ_{s}_{d}", .{ v.token, v.command_id });
        const r: agent.Request = .{ .id = id, .action = std.meta.stringToEnum(@FieldType(agent.Request, "action"), action) orelse return error.InvalidAction, .work = v.work, .serial = v.serial, .wwn = v.wwn, .case = std.meta.stringToEnum(@FieldType(agent.Request, "case"), case) orelse return error.InvalidCase };
        try r.validate();
        try v.domain.?.sendAgent(try v.a.print("{s}\n", .{try std.json.Stringify.valueAlloc(v.a, r, .{})}));
        if (r.action == .reboot or r.action == .shutdown or r.action == .restart) return;
        const until = v.now() + v.timeout_ms;
        var reader: agent.Responses = .{ .cursor = start };
        while (v.now() < until) {
            if (try reader.next(v.a, v.transcript.bytes.items, id)) |response| {
                // Keep decoded output separate from the serial transcript:
                // a read can end with half of the next heartbeat line.
                v.last_guest_stdout = response.stdout;
                if (!response.ok) {
                    std.debug.print("Guest {s} failed: {s}\n{s}\n", .{ action, response.stderr, response.stdout });
                    try v.save("last-command-error.json", response);
                    if (r.action == .install and std.mem.eql(u8, response.stderr, "ArtifactsMissing")) return error.ArtifactsMissing;
                    if (r.action == .servicing) {
                        for ([_][]const u8{ "error: ServiceManagerUnavailable", "error: ServiceStatusUnavailable", "error: ServiceConfigurationUnavailable" }) |temporary| {
                            if (std.mem.indexOf(u8, response.stderr, temporary) != null) return error.ServicingTemporarilyUnavailable;
                        }
                    }
                    return error.GuestCommandFailed;
                }
                return;
            }
            try v.pump();
        }
        return error.GuestCommandTimeout;
    }
    pub fn collect(v: *Vm) !void {
        const start = v.transcript.mark();
        try v.guest("collect", "accept");
        const dir = try v.path("guest");
        try std.Io.Dir.cwd().createDirPath(v.io, dir);
        var lines = std.mem.splitScalar(u8, if (v.transport == .agent) v.last_guest_stdout else v.transcript.since(start), '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, "\r \t");
            if (!std.mem.startsWith(u8, line, "PZ_FILE:")) continue;
            const colon = std.mem.indexOfScalarPos(u8, line, 8, ':') orelse return error.InvalidGuestArtifact;
            const name = line[8..colon];
            if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\:") != null or std.mem.eql(u8, name, "..")) return error.InvalidGuestArtifact;
            const encoded = line[colon + 1 ..];
            const decoder = std.base64.standard.Decoder;
            const bytes = try v.a.alloc(u8, try decoder.calcSizeForSlice(encoded));
            try decoder.decode(bytes, encoded);
            try std.Io.Dir.cwd().writeFile(v.io, .{ .sub_path = try std.fs.path.join(v.a, &.{ dir, name }), .data = bytes });
        }
    }
    pub fn servicing(v: *Vm) !agent.ServicingStatus {
        try v.guest("servicing", "accept");
        var lines = std.mem.splitScalar(u8, v.last_guest_stdout, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "PZ_SERVICING:")) {
                const status = try std.json.parseFromSliceLeaky(agent.ServicingStatus, v.a, std.mem.trim(u8, line[13..], "\r"), .{});
                try v.save("servicing.json", status);
                return status;
            }
        }
        return error.ServicingStatusMissing;
    }
    fn requireFrozen(v: *Vm) !void {
        const status = try v.servicing();
        if (!status.updates_disabled or status.reboot_pending or status.installer_running or status.update_services_running) return error.BaselineUpdatesNotFrozen;
        v.updates_frozen = true;
    }
    pub fn restartWindows(v: *Vm) !void {
        const start = v.transcript.mark();
        try v.guest("restart", "accept");
        try v.wait("BdsDxe: starting", start);
        try v.login();
    }
    pub fn settleWindows(v: *Vm) !agent.ServicingStatus {
        const until = v.now() + 1800000;
        var quiet: ?i64 = null;
        var restarts: usize = 0;
        while (v.now() < until) {
            const saved_timeout = v.timeout_ms;
            v.timeout_ms = 15000;
            const status_or_error = v.servicing();
            v.timeout_ms = saved_timeout;
            const status = status_or_error catch |err| switch (err) {
                // Installation may reboot while a read-only status is in flight.
                error.GuestCommandTimeout, error.ServicingTemporarilyUnavailable => {
                    quiet = null;
                    const pause = v.now() + 5000;
                    while (v.now() < pause) try v.pump();
                    continue;
                },
                else => return err,
            };
            std.debug.print("Servicing: pending={}, installer={}, disabled={}, uptime={d}s\n", .{ status.reboot_pending, status.installer_running, status.updates_disabled, status.uptime_ms / 1000 });
            if (status.reboot_pending and !status.installer_running and status.uptime_ms >= 60000) {
                restarts += 1;
                if (restarts > 8) return error.ServicingRebootLimit;
                quiet = null;
                try v.restartWindows();
                continue;
            }
            if (!status.reboot_pending and !status.installer_running and status.uptime_ms >= 60000) {
                if (quiet == null) quiet = v.now();
                if (v.now() - quiet.? >= 60000) return status;
            } else quiet = null;
            const pause = v.now() + 5000;
            while (v.now() < pause) try v.pump();
        }
        return error.ServicingDidNotSettle;
    }
    pub fn scenario(v: *Vm, case: []const u8) !void {
        var selected = false;
        var it = std.mem.splitScalar(u8, v.cases, ',');
        while (it.next()) |item| if (std.mem.eql(u8, item, case)) {
            selected = true;
            break;
        };
        if (!selected) return error.SkipZigTest;
        _ = try vm_common.cases.run(v, case);
        try v.login();
        try v.guest("verify", case);
        try v.collect();
        const verification = try std.json.parseFromSliceLeaky(struct { case: []const u8, outcome: []const u8, id: []const u8, hash: []const u8, receipt: struct { image_digest: []const u8, program_digest: []const u8 }, idempotent: bool }, v.a, try std.Io.Dir.cwd().readFileAlloc(v.io, try v.path(try v.a.print("guest/{s}-verify.json", .{case})), v.a, .limited(512 * 1024 * 1024)), .{ .ignore_unknown_fields = true });
        const image_hash = try hashFile(v.io, try std.fs.path.join(v.a, &.{ v.stage, "maint.efi" }));
        if (!std.mem.eql(u8, &image_hash.sha256, verification.receipt.image_digest) or verification.receipt.program_digest.len != 64) return error.ReceiptImageMismatch;
        try v.results.append(v.a, .{ .case = case, .outcome = verification.outcome, .id = verification.id, .hash = verification.hash });
        try v.save("results.json", .{ .status = "running", .native = v.native, .results = v.results.items });
    }
    pub fn powercut(v: *Vm) !void {
        try v.event("fault:libvirt-destroy");
        try v.domain.?.stop();
    }
    pub fn finish(v: *Vm) !void {
        try v.collect();
        try v.guest("shutdown", "accept");
        const until = v.now() + 60000;
        while (v.now() < until) {
            const state = try v.domain.?.state();
            if (state.state == c_api.VIR_DOMAIN_SHUTOFF) break;
            _ = c_api.usleep(100000);
        }
        if ((try v.domain.?.state()).state != c_api.VIR_DOMAIN_SHUTOFF) return error.ShutdownTimeout;
        if (!std.mem.eql(u8, v.boot_id, try vm_common.hostBootId(v.a, v.io))) return error.HostRebooted;
        try v.save("results.json", .{ .status = "passed", .native = v.native, .results = v.results.items, .host_boot_id = v.boot_id });
    }
    pub fn failure(v: *Vm, err: anyerror) void {
        if (v.domain) |*d| d.screenshot(v.io, v.path("failure.png") catch return) catch {};
        v.save("results.json", .{ .status = "failed", .err = @errorName(err), .native = v.native, .results = v.results.items }) catch {};
        // Preserve per-command stdout/stderr while the guest is still alive.
        // This is read-only evidence collection, never a retry of the failure.
        if (v.transport == .agent and v.domain != null and v.command_id > 1) {
            const saved = v.timeout_ms;
            v.timeout_ms = 15000;
            v.collect() catch {};
            v.timeout_ms = saved;
        }
        std.debug.print("VM test failed: {s}; artifacts: {s}\n", .{ @errorName(err), v.out });
    }
};
