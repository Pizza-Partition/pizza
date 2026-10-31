//! Rootless QEMU acceptance. Only newly created file-backed guest disks are writable.
const std = @import("std");
const u = @import("common");
const A = std.mem.Allocator;
const artifacts = [_][]const u8{ "pizza-backend", "linux-vm-guest", "maint.efi", "linux-tests/domain-tests", "linux-tests/protocol-tests", "linux-tests/host-tests", "linux-tests/image-tests" };
const Artifact = struct { name: []const u8, sha256: []const u8 };
fn digest(a: A, io: std.Io, path: []const u8) ![]const u8 {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    var at: u64 = 0;
    while (true) {
        const n = try f.readPositionalAll(io, &buf, at);
        if (n == 0) break;
        h.update(buf[0..n]);
        at += n;
    }
    return a.dupe(u8, &std.fmt.bytesToHex(h.finalResult(), .lower));
}
const Host = struct {
    a: A,
    io: std.Io,
    out: []const u8,
    stage: []const u8,
    base: []const u8,
    timeout: i64 = 600,
    accel: []const u8 = "tcg",
    sector: u32 = 512,
    cases: []const u8 = u.cases.csv,
    native: bool = true,
    token: []const u8,
    serial: []const u8,
    wwn: []const u8,
    boot_id: []const u8,
    child: ?std.process.Child = null,
    log: ?std.Io.File = null,
    transcript: std.ArrayList(u8) = .empty,
    offset: u64 = 0,
    id: u32 = 0,
    stdout: []const u8 = "",
    results: std.ArrayList(std.json.Value) = .empty,
    pub fn now(h: Host) i64 {
        return std.Io.Clock.awake.now(h.io).toMilliseconds();
    }
    pub fn endTime(h: Host) i64 {
        return h.now() + h.timeout * 1000;
    }
    pub fn consoleMark(h: Host) usize {
        return h.transcript.items.len;
    }
    pub fn contains(h: Host, start: usize, needle: []const u8) bool {
        return std.mem.indexOf(u8, h.transcript.items[start..], needle) != null;
    }
    fn path(h: Host, name: []const u8) ![]const u8 {
        return std.fs.path.join(h.a, &.{ h.out, name });
    }
    fn command(h: Host, argv: []const []const u8, input: ?[]const u8) ![]const u8 {
        return u.check(try u.runAt(h.a, h.io, null, .inherit, argv, input, h.timeout));
    }
    fn copy(h: Host, from: []const u8, to: []const u8) !void {
        try std.Io.Dir.cwd().copyFile(from, .cwd(), to, h.io, .{ .make_path = true });
        const source = try std.Io.Dir.cwd().openFile(h.io, from, .{});
        defer source.close(h.io);
        const dest = try std.Io.Dir.cwd().openFile(h.io, to, .{});
        defer dest.close(h.io);
        try dest.setPermissions(h.io, (try source.stat(h.io)).permissions);
    }
    fn save(h: Host, name: []const u8, v: anytype) !void {
        try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try h.path(name), .data = try std.json.Stringify.valueAlloc(h.a, v, .{ .whitespace = .indent_2 }) });
    }
    fn write(h: Host, name: []const u8, bytes: []const u8) !void {
        const p = try h.path(name);
        try std.Io.Dir.cwd().createDirPath(h.io, std.fs.path.dirname(p).?);
        try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = p, .data = bytes });
    }
    fn event(h: Host, phase: []const u8) !void {
        std.debug.print("{s}\n", .{phase});
        const f = try std.Io.Dir.cwd().createFile(h.io, try h.path("events.jsonl"), .{ .truncate = false });
        defer f.close(h.io);
        try f.writePositionalAll(h.io, try h.a.print("{s}\n", .{try std.json.Stringify.valueAlloc(h.a, .{ .ms = std.Io.Clock.awake.now(h.io).toMilliseconds(), .phase = phase }, .{})}), (try f.stat(h.io)).size);
    }
    fn rootDest(h: Host, source: []const u8) ![]const u8 {
        const tail = if (std.mem.startsWith(u8, source, "/usr/lib/")) try h.a.print("opt/pizza/bundle/lib/{s}", .{source[9..]}) else if (std.mem.startsWith(u8, source, "/usr/bin/")) try h.a.print("opt/pizza/bundle/bin/{s}", .{source[9..]}) else if (std.mem.startsWith(u8, source, "/usr/lib64/")) try h.a.print("opt/pizza/bundle/lib/{s}", .{source[11..]}) else if (std.mem.startsWith(u8, source, "/lib64/")) try h.a.print("opt/pizza/bundle/lib/{s}", .{source[7..]}) else return error.UnsupportedDependencyPath;
        return h.path(try h.a.print("root/{s}", .{tail}));
    }
    fn withLibs(h: Host, source: []const u8, dest: []const u8) !void {
        try h.copy(source, dest);
        const f = try std.Io.Dir.cwd().openFile(h.io, source, .{});
        const st = try f.stat(h.io);
        f.close(h.io);
        const target = try std.Io.Dir.cwd().openFile(h.io, dest, .{});
        try target.setPermissions(h.io, st.permissions);
        target.close(h.io);
        if (std.mem.endsWith(u8, source, "/domain-tests") or std.mem.endsWith(u8, source, "/protocol-tests")) return;
        const result = try u.runAt(h.a, h.io, null, .inherit, &.{ "ldd", source }, null, 30);
        if (!result.term.success()) {
            if (std.mem.indexOf(u8, result.stderr, "not a dynamic executable") != null or std.mem.indexOf(u8, result.stdout, "statically linked") != null) return;
            std.debug.print("ldd {s}: {s}{s}\n", .{ source, result.stdout, result.stderr });
            return error.DependencyDiscoveryFailed;
        }
        var words = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
        while (words.next()) |word| if (std.mem.startsWith(u8, word, "/")) try h.copy(word, try h.rootDest(word));
    }
    fn provision(h: *Host, maintenance: []const u8, kernel: []const u8, initrd: []const u8, ukify: []const u8) !void {
        try h.event("provision:extract-maintenance-runtime");
        const root = try h.path("root");
        try std.Io.Dir.cwd().createDir(h.io, root, .default_dir);
        _ = try h.command(&.{ "bsdtar", "-xf", try std.fs.path.join(h.a, &.{ maintenance, "maint.img" }), "-C", root }, null);
        // The initramfs tests the init path before chroot, so top-level links
        // must also resolve within the extracted root at that point.
        for ([_][2][]const u8{ .{ "bin", "opt/pizza/bundle/bin" }, .{ "sbin", "opt/pizza/bundle/bin" }, .{ "usr/bin", "../opt/pizza/bundle/bin" }, .{ "usr/sbin", "../opt/pizza/bundle/bin" }, .{ "usr/lib", "../opt/pizza/bundle/lib" }, .{ "usr/share", "../opt/pizza/bundle/share" } }) |link| _ = try h.command(&.{ "ln", "-sfn", link[1], try h.path(try h.a.print("root/{s}", .{link[0]})) }, null);
        // Bundle root uses absolute /usr links. Always address their in-image destinations.
        _ = try h.command(&.{ "cp", "-a", "/usr/lib/systemd", try h.path("root/opt/pizza/bundle/lib/") }, null);
        _ = try h.command(&.{ "cp", "-a", "/usr/lib/udev", try h.path("root/opt/pizza/bundle/lib/") }, null);
        _ = try h.command(&.{ "ln", "-s", "opt/pizza/bundle/lib", try h.path("root/lib64") }, null);
        for ([_][]const u8{ "/usr/lib/systemd/systemd", "/usr/lib/systemd/systemd-executor", "/usr/lib/systemd/systemd-shutdown", "/usr/bin/systemctl", "/usr/bin/udevadm", "/usr/bin/mount", "/usr/bin/umount", "/usr/bin/stty", "/usr/bin/kmod", "/usr/bin/mke2fs", "/usr/bin/mkfs.ext4", "/usr/bin/e2fsck", "/usr/bin/resize2fs", "/usr/bin/tune2fs", "/usr/bin/blkid", "/usr/bin/sfdisk", "/usr/bin/mkfs.vfat", "/usr/bin/systemd-tmpfiles", "/usr/bin/systemd-sysusers", "/usr/bin/journalctl" }) |file| try h.withLibs(file, try h.rootDest(file));
        const metadata = try std.json.parseFromSliceLeaky(struct { kernel_version: []const u8 }, h.a, try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ maintenance, "maint.img.pizza.json" }), h.a, .limited(512 * 1024 * 1024)), .{ .ignore_unknown_fields = true });
        for ([_][]const u8{ "fat", "nls" }) |name| {
            const dest = try h.path(try h.a.print("root/lib/modules/{s}/kernel/fs", .{metadata.kernel_version}));
            try std.Io.Dir.cwd().createDirPath(h.io, dest);
            _ = try h.command(&.{ "cp", "-a", try h.a.print("/usr/lib/modules/{s}/kernel/fs/{s}", .{ metadata.kernel_version, name }), dest }, null);
        }
        for ([_][]const u8{ "modules.builtin", "modules.builtin.modinfo" }) |name| try h.copy(try h.a.print("/usr/lib/modules/{s}/{s}", .{ metadata.kernel_version, name }), try h.path(try h.a.print("root/lib/modules/{s}/{s}", .{ metadata.kernel_version, name })));
        _ = try h.command(&.{ "depmod", "-b", root, metadata.kernel_version }, null);
        // Pin libblockdev's dlopen plugins to the same host build as the product.
        var lib = try std.Io.Dir.cwd().openDir(h.io, "/usr/lib", .{ .iterate = true });
        defer lib.close(h.io);
        var it = lib.iterate();
        while (try it.next(h.io)) |e| if (std.mem.startsWith(u8, e.name, "libbd_") and std.mem.endsWith(u8, e.name, ".so.3")) {
            const p = try h.a.print("/usr/lib/{s}", .{e.name});
            try h.withLibs(p, try h.rootDest(p));
        };
        for ([_][]const u8{ "pizza-backend", "linux-vm-guest", "linux-tests/domain-tests", "linux-tests/protocol-tests", "linux-tests/host-tests", "linux-tests/image-tests" }) |name| {
            const dest = try h.path(try h.a.print("root/opt/tests/{s}", .{name}));
            try std.Io.Dir.cwd().createDirPath(h.io, std.fs.path.dirname(dest).?);
            try h.withLibs(try std.fs.path.join(h.a, &.{ h.stage, name }), dest);
        }
        try h.copy(try std.fs.path.join(h.a, &.{ h.stage, "maint.efi" }), try h.path("root/opt/tests/maint.efi"));
        for ([_][]const u8{ "root/mnt/keep", "root/run", "root/tmp", "root/var/lib", "root/etc/systemd/system/pizza-test.target.wants" }) |p| try std.Io.Dir.cwd().createDirPath(h.io, try h.path(p));
        try h.write("root/etc/machine-id", "");
        try h.write("root/etc/fstab", "");
        try h.write("root/etc/systemd/system/pizza-test.target", "[Unit]\nDescription=Isolated Pizza acceptance\nRequires=basic.target systemd-udevd.service pizza-agent.service\nAfter=basic.target systemd-udevd.service\nAllowIsolate=yes\n");
        try h.write("root/etc/systemd/system/pizza-agent.service", "[Unit]\nDescription=Serial Zig acceptance agent\nAfter=systemd-udevd.service\n[Service]\nType=simple\nExecStartPre=/usr/bin/udevadm trigger --action=add\nExecStartPre=/usr/bin/udevadm settle\nExecStart=/opt/tests/linux-vm-guest --agent\nStandardInput=tty\nStandardOutput=tty\nStandardError=tty\nTTYPath=/dev/ttyS0\nEnvironment=PATH=/usr/sbin:/usr/bin:/sbin:/bin\nEnvironment=LD_LIBRARY_PATH=/opt/pizza/bundle/lib\nTimeoutStopSec=5\n");
        // Consistent /usr paths for the copied host binaries; bundle tools retain their RPATH.
        try h.write("root/etc/ld.so.conf", "/opt/pizza/bundle/lib\n");

        const esp = try h.path("esp.raw");
        const fs = try h.path("root.raw");
        const system = try h.path("linux.raw");
        _ = try h.command(&.{ "qemu-img", "create", "-f", "raw", esp, "256M" }, null);
        _ = try h.command(&.{ "mkfs.vfat", "-F", "32", "-n", "PZBOOT", esp }, null);
        const main_efi = try h.path("main.efi");
        _ = try h.command(&.{ ukify, "build", "--linux", kernel, "--initrd", initrd, "--cmdline", "root=LABEL=PZROOT rw fsck.mode=skip init=/usr/lib/systemd/systemd console=tty0 console=ttyS0,115200n8 loglevel=4 systemd.unit=pizza-test.target", "--stub", "/usr/lib/systemd/boot/efi/linuxx64.efi.stub", "--output", main_efi }, null);
        _ = try h.command(&.{ "mmd", "-i", esp, "::/EFI", "::/EFI/BOOT" }, null);
        _ = try h.command(&.{ "mcopy", "-i", esp, main_efi, "::/EFI/BOOT/BOOTX64.EFI" }, null);
        const tar = try h.path("root.tar");
        _ = try h.command(&.{ "bsdtar", "--uid", "0", "--gid", "0", "-cf", tar, "-C", root, "." }, null);
        _ = try h.command(&.{ "qemu-img", "create", "-f", "raw", fs, "3G" }, null);
        _ = try h.command(&.{ "mkfs.ext4", "-F", "-L", "PZROOT", "-d", tar, fs }, null);
        _ = try h.command(&.{ "qemu-img", "create", "-f", "raw", system, "4G" }, null);
        _ = try h.command(&.{ "sfdisk", system }, "label: gpt\nstart=2048,size=524288,type=U\nstart=526336,size=6291456,type=L\n");
        _ = try h.command(&.{ "dd", try h.a.print("if={s}", .{esp}), try h.a.print("of={s}", .{system}), "bs=1M", "seek=1", "conv=sparse,notrunc", "status=none" }, null);
        _ = try h.command(&.{ "dd", try h.a.print("if={s}", .{fs}), try h.a.print("of={s}", .{system}), "bs=1M", "seek=257", "conv=sparse,notrunc", "status=none" }, null);
        try h.copy("/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd", try h.path("OVMF_CODE.fd"));
        try h.copy("/usr/share/edk2/x64/OVMF_VARS.4m.fd", try h.path("OVMF_VARS.fd"));
        for ([_][]const u8{ "linux.raw", "OVMF_CODE.fd", "OVMF_VARS.fd" }) |name| {
            const f = try std.Io.Dir.cwd().openFile(h.io, try h.path(name), .{});
            try f.setPermissions(h.io, .fromMode(0o444));
            f.close(h.io);
        }
        var baked: [artifacts.len]Artifact = undefined;
        for (artifacts, 0..) |name, i| baked[i] = .{ .name = name, .sha256 = try digest(h.a, h.io, try h.path(try h.a.print("root/opt/tests/{s}", .{name}))) };
        try h.save("baseline.json", .{ .version = 2, .system_sha256 = try digest(h.a, h.io, system), .code_sha256 = try digest(h.a, h.io, try h.path("OVMF_CODE.fd")), .vars_sha256 = try digest(h.a, h.io, try h.path("OVMF_VARS.fd")), .artifacts = baked, .kernel_sha256 = try digest(h.a, h.io, kernel), .initrd_sha256 = try digest(h.a, h.io, initrd) });
        try h.event("provision:ready");
    }
    pub fn powercut(h: *Host) !void {
        const child = if (h.child) |*child| child else return error.NoRunningGuest;
        const rc = std.os.linux.kill(child.id orelse return error.NoRunningGuest, .KILL);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.PowercutFailed;
        child.kill(h.io);
        h.child = null;
        // Include all pre-cut output before the caller records its recovery cursor.
        try h.pump();
        try h.event("fault:qemu-sigkill");
    }
    fn stop(h: *Host) void {
        if (h.child) |*child| child.kill(h.io);
        h.child = null;
    }
    pub fn boot(h: *Host) !void {
        h.stop();
        const args = &.{ "qemu-system-x86_64", "-machine", "q35", "-accel", h.accel, "-cpu", if (std.mem.eql(u8, h.accel, "kvm")) "host" else "max", "-m", "4096", "-smp", "2", "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none", "-drive", try h.a.print("if=pflash,format=raw,readonly=on,file={s}/OVMF_CODE.fd", .{h.base}), "-drive", try h.a.print("if=pflash,format=raw,file={s}/OVMF_VARS.fd", .{h.out}), "-drive", try h.a.print("if=none,id=system,format=qcow2,file={s}/linux.qcow2", .{h.out}), "-device", "nvme,serial=PZ_SYSTEM,drive=system", "-device", "virtio-scsi-pci,id=scsi", "-drive", try h.a.print("if=none,id=target,format=raw,cache=none,file={s}/target.raw", .{h.out}), "-device", try h.a.print("scsi-hd,drive=target,bus=scsi.0,serial={s},wwn=0x{s},logical_block_size={d},physical_block_size={d}", .{ h.serial, h.wwn, h.sector, h.sector }) };
        try h.save("qemu-argv.json", args);
        h.child = try std.process.spawn(h.io, .{ .argv = args, .stdin = .pipe, .stdout = .{ .file = h.log.? }, .stderr = .{ .file = h.log.? } });
        try h.event("boot");
    }
    pub fn pump(h: *Host) !void {
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = try h.log.?.readPositionalAll(h.io, &buf, h.offset);
            if (n == 0) break;
            try h.transcript.appendSlice(h.a, buf[0..n]);
            h.offset += n;
        }
        try std.Io.sleep(h.io, .fromMilliseconds(25), .awake);
    }
    pub fn wait(h: *Host, needle: []const u8, start: usize) !void {
        const end = std.Io.Clock.awake.now(h.io).toMilliseconds() + h.timeout * 1000;
        while (std.Io.Clock.awake.now(h.io).toMilliseconds() < end) {
            try h.pump();
            if (std.mem.indexOf(u8, h.transcript.items[start..], needle) != null) return;
        }
        std.debug.print("Timeout waiting for {s}; see {s}/serial.log\n", .{ needle, h.out });
        return error.ConsoleTimeout;
    }
    pub fn send(h: *Host, bytes: []const u8) !void {
        try h.child.?.stdin.?.writeStreamingAll(h.io, bytes);
    }
    pub fn guest(h: *Host, action: []const u8, case: []const u8) !void {
        const start = h.transcript.items.len;
        h.id += 1;
        try h.event(try h.a.print("guest:{s}:{s}", .{ action, case }));
        try h.send(try h.a.print("{s}\n", .{try std.json.Stringify.valueAlloc(h.a, .{ .id = h.id, .action = action, .serial = h.serial, .wwn = h.wwn, .case = case }, .{})}));
        if (std.mem.eql(u8, action, "reboot") or std.mem.eql(u8, action, "shutdown")) return;
        const end = std.Io.Clock.awake.now(h.io).toMilliseconds() + h.timeout * 1000;
        var cursor = start;
        while (std.Io.Clock.awake.now(h.io).toMilliseconds() < end) {
            try h.pump();
            while (std.mem.indexOfScalarPos(u8, h.transcript.items, cursor, '\n')) |line_end| {
                const line = std.mem.trim(u8, h.transcript.items[cursor..line_end], "\r");
                cursor = line_end + 1;
                if (!std.mem.startsWith(u8, line, "PZ_LINUX:")) continue;
                const r = try std.json.parseFromSliceLeaky(struct { id: u32, ok: bool, stdout: []const u8, stderr: []const u8 }, h.a, line[9..], .{});
                if (r.id != h.id) continue;
                try h.save("last-command.json", r);
                if (!r.ok) {
                    std.debug.print("Guest {s}: {s}\n{s}\n", .{ action, r.stderr, r.stdout });
                    return error.GuestFailed;
                }
                h.stdout = r.stdout;
                return;
            }
        }
        return error.GuestTimeout;
    }
    fn collect(h: *Host) !void {
        try h.guest("collect", "accept");
        var lines = std.mem.splitScalar(u8, h.stdout, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "PZ_FILE:")) continue;
            const colon = std.mem.indexOfScalarPos(u8, line, 8, ':') orelse return error.InvalidEvidence;
            const name = line[8..colon];
            if (std.mem.indexOfAny(u8, name, "/\\") != null) return error.InvalidEvidence;
            const enc = line[colon + 1 ..];
            const dec = std.base64.standard.Decoder;
            const bytes = try h.a.alloc(u8, try dec.calcSizeForSlice(enc));
            try dec.decode(bytes, enc);
            try h.write(try h.a.print("guest/{s}", .{name}), bytes);
        }
    }
    fn scenario(h: *Host, case: []const u8) !void {
        const start = try u.cases.run(h, case);
        try h.wait("PZ_LINUX_READY", start);
        try h.guest("verify", case);
        try h.collect();
        const v = try std.json.parseFromSliceLeaky(std.json.Value, h.a, try std.Io.Dir.cwd().readFileAlloc(h.io, try h.path(try h.a.print("guest/{s}-verify.json", .{case})), h.a, .limited(512 * 1024 * 1024)), .{});
        const receipt = v.object.get("receipt").?.object;
        if (!std.mem.eql(u8, receipt.get("image_digest").?.string, try digest(h.a, h.io, try std.fs.path.join(h.a, &.{ h.stage, "maint.efi" })))) return error.ReceiptImageMismatch;
        try h.results.append(h.a, v);
        try h.save("results.json", .{ .status = "running", .native = h.native, .sector_size = h.sector, .results = h.results.items });
    }
    fn run(h: *Host) !void {
        for ([_][]const u8{ "linux.raw", "OVMF_CODE.fd", "OVMF_VARS.fd" }) |name| {
            const st = try std.Io.Dir.cwd().statFile(h.io, try std.fs.path.join(h.a, &.{ h.base, name }), .{});
            if (!st.permissions.readOnly()) return error.ReadonlyBaselineRequired;
        }
        const baseline = try std.json.parseFromSliceLeaky(struct { version: u32, system_sha256: []const u8, code_sha256: []const u8, vars_sha256: []const u8, artifacts: []Artifact }, h.a, try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ h.base, "baseline.json" }), h.a, .limited(512 * 1024 * 1024)), .{ .ignore_unknown_fields = true });
        if (baseline.version != 2 or baseline.artifacts.len != artifacts.len) return error.InvalidBaseline;
        for ([_][2][]const u8{ .{ "linux.raw", baseline.system_sha256 }, .{ "OVMF_CODE.fd", baseline.code_sha256 }, .{ "OVMF_VARS.fd", baseline.vars_sha256 } }) |file| if (!std.mem.eql(u8, file[1], try digest(h.a, h.io, try std.fs.path.join(h.a, &.{ h.base, file[0] })))) return error.BaselineChanged;
        for (artifacts, baseline.artifacts) |name, baked| {
            if (!std.mem.eql(u8, name, baked.name) or !std.mem.eql(u8, baked.sha256, try digest(h.a, h.io, try std.fs.path.join(h.a, &.{ h.stage, name })))) return error.StagedArtifactsChanged;
        }
        try h.copy(try std.fs.path.join(h.a, &.{ h.base, "baseline.json" }), try h.path("baseline.json"));
        try h.copy(try std.fs.path.join(h.a, &.{ h.base, "OVMF_VARS.fd" }), try h.path("OVMF_VARS.fd"));
        const vars = try std.Io.Dir.cwd().openFile(h.io, try h.path("OVMF_VARS.fd"), .{});
        try vars.setPermissions(h.io, .fromMode(0o600));
        vars.close(h.io);
        _ = try h.command(&.{ "qemu-img", "create", "-f", "qcow2", "-F", "raw", "-b", try std.fs.path.join(h.a, &.{ h.base, "linux.raw" }), try h.path("linux.qcow2") }, null);
        _ = try h.command(&.{ "qemu-img", "create", "-f", "raw", try h.path("target.raw"), "4G" }, null);
        try h.save("inputs.json", .{ .base = h.base, .stage = h.stage, .serial = h.serial, .wwn = h.wwn, .sector_size = h.sector, .native = h.native, .network = false, .host_boot_id = h.boot_id, .cases = h.cases, .accel = h.accel });
        h.log = try std.Io.Dir.cwd().createFile(h.io, try h.path("serial.log"), .{ .read = true });
        defer h.log.?.close(h.io);
        defer h.stop();
        try h.boot();
        try h.wait("PZ_LINUX_READY", 0);
        errdefer h.collect() catch {};
        if (h.native) try h.guest("native", "accept");
        try h.guest("setup", "accept");
        var cases = std.mem.splitScalar(u8, h.cases, ',');
        while (cases.next()) |case| try h.scenario(case);
        try h.guest("shutdown", "accept");
        try h.wait("Power down", h.transcript.items.len);
        const term = try h.child.?.wait(h.io);
        h.child = null;
        if (!term.success()) return error.ShutdownFailed;
        if (!std.mem.eql(u8, h.boot_id, try u.hostBootId(h.a, h.io))) return error.HostRebooted;
        try h.save("results.json", .{ .status = "passed", .native = h.native, .sector_size = h.sector, .results = h.results.items, .host_boot_id = h.boot_id });
    }
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 1 or (args.len == 2 and std.mem.eql(u8, args[1], "--help"))) {
        try std.Io.File.stdout().writeStreamingAll(io, "linux-vm provision|run --out NEW_DIR --stage BIN_DIR [--base BASE_DIR] [--maintenance PAYLOAD_DIR --kernel FILE --initrd FILE --ukify FILE] [--sector 512|4096] [--accel kvm|tcg] [--cases accept,undo,powercut-undo,powercut-accept,powercut-apply] [--native run|skip] [--timeout SECONDS]\n");
        return;
    }
    var options: std.StringHashMap([]const u8) = .init(a);
    if (!std.mem.eql(u8, args[1], "provision") and !std.mem.eql(u8, args[1], "run")) return error.InvalidMode;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len or !std.mem.startsWith(u8, args[i], "--")) return error.InvalidArguments;
        var known = false;
        for ([_][]const u8{ "--out", "--stage", "--base", "--maintenance", "--kernel", "--initrd", "--ukify", "--sector", "--accel", "--cases", "--native", "--timeout" }) |option| if (std.mem.eql(u8, args[i], option)) {
            known = true;
            break;
        };
        if (!known) return error.UnknownOption;
        if (options.contains(args[i])) return error.DuplicateOption;
        try options.put(args[i], args[i + 1]);
    }
    const cwd = try std.process.currentPathAlloc(io, a);
    const out = try std.fs.path.resolve(a, &.{ cwd, options.get("--out") orelse return error.OutputRequired });
    const stage = try std.fs.path.resolve(a, &.{ cwd, options.get("--stage") orelse return error.StageRequired });
    const base = try std.fs.path.resolve(a, &.{ cwd, options.get("--base") orelse out });
    for ([_][]const u8{ out, stage, base }) |p| if (std.mem.indexOfAny(u8, p, ",\r\n") != null) return error.UnsafePath;
    var random: [6]u8 = undefined;
    io.random(&random);
    const token = try a.dupe(u8, &std.fmt.bytesToHex(random, .lower));
    var h: Host = .{ .a = a, .io = io, .out = out, .stage = stage, .base = base, .token = token, .serial = try a.print("PZ-E2E-{s}", .{token}), .wwn = try a.print("5001{s}", .{token}), .boot_id = try u.hostBootId(a, io) };
    if (options.get("--sector")) |s| h.sector = try std.fmt.parseInt(u32, s, 10);
    if (h.sector != 512 and h.sector != 4096) return error.InvalidSector;
    if (options.get("--timeout")) |s| h.timeout = try std.fmt.parseInt(i64, s, 10);
    if (h.timeout < 1 or h.timeout > 3600) return error.InvalidTimeout;
    if (options.get("--accel")) |s| h.accel = s;
    if (!std.mem.eql(u8, h.accel, "kvm") and !std.mem.eql(u8, h.accel, "tcg")) return error.InvalidAccelerator;
    if (options.get("--cases")) |s| h.cases = s;
    try u.cases.validate(h.cases);
    if (options.get("--native")) |s| {
        if (std.mem.eql(u8, s, "skip")) h.native = false else if (!std.mem.eql(u8, s, "run")) return error.InvalidNative;
    }
    try std.Io.Dir.cwd().createDir(io, out, .fromMode(0o700));
    if (std.mem.eql(u8, args[1], "provision")) {
        try h.provision(options.get("--maintenance") orelse return error.MaintenanceRequired, options.get("--kernel") orelse "/boot/vmlinuz-linux", options.get("--initrd") orelse "/boot/initramfs-linux.img", options.get("--ukify") orelse return error.UkifyRequired);
    } else if (std.mem.eql(u8, args[1], "run")) {
        h.run() catch |err| {
            h.save("results.json", .{ .status = "failed", .err = @errorName(err), .native = h.native, .sector_size = h.sector, .results = h.results.items }) catch {};
            return err;
        };
    } else return error.InvalidMode;
}
