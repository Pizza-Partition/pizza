//! Linux guest acceptance uses the built product CLI on a serial-bound test disk.
const std = @import("std");
const vm_common = @import("vm_common");
const proto = @import("proto");
const wire = proto.wire;
const editor = @import("core/planning/editor.zig");
const libc = @import("libc");
const shared = @import("shared_guest.zig");
const Guest = shared.Guest(Platform);
const MIB = 1024 * 1024;
const Platform = struct {
    pub const extension = "";
    pub const test_dir = "linux-tests";
    pub fn target(g: Guest, s: wire.InventorySnapshot) !wire.HostDisk {
        const device_path = try Platform.device(g);
        for (s.disks) |d| if (std.mem.eql(u8, d.path, device_path)) {
            if (try proto.byteCount(d.capacity) != 4 * 1024 * MIB or d.read_only or d.identity == null) return error.ForeignDiskRejected;
            return d;
        };
        return error.TargetMissing;
    }
    pub fn device(g: Guest) ![]const u8 {
        // Fixed QEMU target is still admitted by two independent hardware properties.
        const serial = sysText(g.a, g.io, "/sys/class/block/sda/device/serial") catch blk: {
            const vpd = try sysText(g.a, g.io, "/sys/class/block/sda/device/vpd_pg80");
            if (vpd.len < 4) return error.ForeignDiskRejected;
            break :blk std.mem.trim(u8, vpd[4..], " \x00");
        };
        const wwid = try sysText(g.a, g.io, "/sys/class/block/sda/device/wwid");
        if (!std.mem.eql(u8, serial, g.serial) or !std.mem.eql(u8, wwid, try g.a.print("naa.{s}", .{g.wwn}))) return error.ForeignDiskRejected;
        return "/dev/sda";
    }
    pub fn fileHash(g: Guest, d: wire.HostDisk) ![]const u8 {
        for (d.partitions) |p| if (p.filesystem == .ext4) {
            _ = try g.program("mount-read", &.{ "/usr/bin/mount", "-o", "ro", p.path orelse return error.VolumeMissing, "/mnt/keep" }, null);
            defer {
                _ = vm_common.runAt(g.a, g.io, null, .inherit, &.{ "/usr/bin/umount", "/mnt/keep" }, null, 30) catch {};
            }
            const bytes = try std.Io.Dir.cwd().readFileAlloc(g.io, "/mnt/keep/pizza-sentinel.bin", g.a, .limited(512 * 1024 * 1024));
            if (bytes.len != 2 * MIB) return error.SentinelSizeChanged;
            return g.a.dupe(u8, &vm_common.hash(bytes));
        };
        return error.SentinelMissing;
    }
    pub fn setup(g: Guest) !void {
        const d = try Platform.target(g, try g.snapshot());
        if (d.partition_table != null or d.partitions.len != 0) return error.NonemptyTargetRejected;
        const sector = d.sector_size;
        _ = try g.program("partition", &.{ "/usr/bin/sfdisk", try Platform.device(g) }, try g.a.print("label: gpt\nstart={d},size={d},type=U\nstart={d},size={d},type=L\n", .{ 32 * MIB / sector, 512 * MIB / sector, 544 * MIB / sector, 512 * MIB / sector }));
        _ = try g.program("format-esp", &.{ "/usr/bin/mkfs.vfat", "-F", "32", "-n", "PizzaESP", "/dev/sda1" }, null);
        _ = try g.program("format-data", &.{ "/usr/bin/mkfs.ext4", "-F", "-L", "PizzaKeep", "/dev/sda2" }, null);
        _ = try g.program("mount-write", &.{ "/usr/bin/mount", "/dev/sda2", "/mnt/keep" }, null);
        const bytes = try g.a.alloc(u8, 2 * MIB);
        g.io.random(bytes);
        const f = try std.Io.Dir.cwd().createFile(g.io, "/mnt/keep/pizza-sentinel.bin", .{ .exclusive = true });
        try f.writeStreamingAll(g.io, bytes);
        try f.sync(g.io);
        f.close(g.io);
        _ = try g.program("umount-write", &.{ "/usr/bin/umount", "/mnt/keep" }, null);
    }
    pub fn edit(g: Guest, request: *editor.Request, initial: editor.Result) !editor.Result {
        const result = initial;
        const parts = try g.a.dupe(wire.DesiredPartition, result.draft.layout);
        for (parts) |*p| if (p.filesystem == .ext4) {
            p.offset = try g.a.print("{d}", .{try proto.byteCount(p.offset) + 64 * MIB});
        };
        request.layout = parts;
        request.review = true;
        return g.pizza(editor.Result, "plan", request.*, "plan");
    }
};
fn sysText(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var buffer: [256]u8 = undefined;
    var reader = f.readerStreaming(io, &buffer);
    return std.mem.trim(u8, try reader.interface.allocRemaining(a, .limited(4096)), " \r\n\t");
}
const Request = struct { id: u32, action: enum { setup, native, plan, prepare, reboot, verify, collect, shutdown }, serial: []const u8, wwn: []const u8, case: vm_common.cases.Case };
extern "c" fn tcdrain(fd: c_int) c_int;
fn serialWrite(io: std.Io, bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const end = @min(at + 256, bytes.len);
        if (!@import("core/platform/linux/session/transport.zig").writeAll(1, bytes[at..end])) return error.SerialWriteFailed;
        if (tcdrain(1) != 0) return error.SerialDrainFailed;
        at = end;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (libc.geteuid() != 0) return error.RootRequired;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--agent")) {
        _ = try vm_common.check(try vm_common.runAt(a, io, null, .inherit, &.{ "/usr/bin/stty", "-F", "/dev/ttyS0", "raw", "-echo" }, null, 30));
        var buf: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(io, &buf);
        try std.Io.File.stdout().writeStreamingAll(io, "PZ_LINUX_READY\n");
        while (true) {
            const line = (try reader.interface.takeDelimiter('\n')) orelse return error.SerialClosed;
            if (line.len == 0) continue;
            if (line.len > 4096) return error.RequestTooLarge;
            const r = try std.json.parseFromSliceLeaky(Request, a, line, .{});
            if (r.serial.len != 19 or r.wwn.len != 16 or !std.mem.startsWith(u8, r.serial, "PZ-E2E-") or !std.mem.startsWith(u8, r.wwn, "5001") or !std.mem.eql(u8, r.serial[7..], r.wwn[4..])) return error.InvalidTarget;
            for (r.serial[7..]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidTarget;
            const result = try vm_common.runAt(a, io, null, .inherit, &.{ "/opt/tests/linux-vm-guest", @tagName(r.action), r.serial, r.wwn, @tagName(r.case) }, null, 600);
            try serialWrite(io, try a.print("PZ_LINUX:{s}\n", .{try std.json.Stringify.valueAlloc(a, .{ .id = r.id, .ok = result.term.success(), .stdout = result.stdout, .stderr = result.stderr }, .{})}));
        }
    }
    if (args.len != 5) return error.ExpectedActionSerialWwnCase;
    const g: Guest = .{ .a = a, .io = io, .serial = args[2], .wwn = args[3], .case = args[4], .work = "/opt/tests" };
    const action = args[1];
    if (std.mem.eql(u8, action, "setup")) try Platform.setup(g) else if (std.mem.eql(u8, action, "native")) {
        try g.runNative();
    } else if (std.mem.eql(u8, action, "plan")) try g.plan() else if (std.mem.eql(u8, action, "prepare")) {
        // Formatting the fixture emits asynchronous device events. Let udev
        // finish probing before the product takes its exclusive ESP disk lock.
        _ = try g.program("udev-settle", &.{ "/usr/bin/udevadm", "settle", "--timeout=30" }, null);
        defer {
            _ = g.program("kernel", &.{"/usr/bin/dmesg"}, null) catch {};
        }
        try g.prepare();
    } else if (std.mem.eql(u8, action, "reboot")) {
        try g.reboot();
    } else if (std.mem.eql(u8, action, "verify")) try g.verify() else if (std.mem.eql(u8, action, "collect")) {
        try g.collect();
    } else if (std.mem.eql(u8, action, "shutdown")) {
        _ = try vm_common.check(try vm_common.runAt(a, io, null, .inherit, &.{ "/usr/bin/systemctl", "--no-block", "poweroff" }, null, 30));
    } else return error.InvalidAction;
    try std.Io.File.stdout().writeStreamingAll(io, "{\"ok\":true}\n");
}
