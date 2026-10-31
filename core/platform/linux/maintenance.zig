//! Linux ports for the common maintenance controller.
const std = @import("std");
const w = @import("proto").wire;
pub const Maintenance = @import("../../boot/maintenance.zig").Maintenance(@This());
pub const Store = @import("maintenance_store.zig");
pub const Esp = @import("esp.zig").Esp;
pub const Firmware = @import("efivars.zig").Efivars;
pub const query = @import("inventory.zig").query;
pub fn records(_: std.mem.Allocator) !Store {
    return Store.open();
}
pub fn executable(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, "/proc/self/exe", a);
}
pub fn openFirmware(io: std.Io, writable: bool) !Firmware {
    return Firmware.open(io, writable) catch |err| switch (err) {
        error.FileNotFound => error.UefiRequired,
        else => err,
    };
}
pub fn closeFirmware(fw: *Firmware, io: std.Io) void {
    fw.close(io);
}
pub fn requireUnsigned(fw: *Firmware, a: std.mem.Allocator, io: std.Io) !void {
    switch (try fw.secureBoot(a, io)) {
        .disabled => {},
        .enabled, .unknown => return error.SignedMaintenanceImageRequired,
    }
}
pub fn verifyDisk(a: std.mem.Allocator, io: std.Io, disk: w.HostDisk) !void {
    // Fresh discovery derives the portable identity; ESP admission additionally
    // pins and rechecks the actual disk and partition descriptors under flock.
    const current = try @import("../../execution/state.zig").disk(try query(a, io), disk.identity orelse return error.MissingDiskIdentity);
    if (!std.mem.eql(u8, current.path, disk.path)) return error.DeviceIdentityChanged;
}
pub fn reboot(a: std.mem.Allocator, io: std.Io) !void {
    // Ask PID 1 to stop services and unmount filesystems normally.
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("PATH", "/usr/sbin:/usr/bin:/sbin:/bin");
    const result = try std.process.run(a, io, .{ .environ_map = &env, .argv = &.{ "/usr/bin/systemctl", "--no-block", "reboot" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) });
    if (!result.term.success()) return error.RebootFailed;
}
