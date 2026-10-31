//! Windows ports for the common maintenance controller.
const std = @import("std");
const proto = @import("proto");
const n = @import("native.zig");
const firmware = @import("firmware.zig");
const security = @import("session/security.zig");
pub const Maintenance = @import("../../boot/maintenance.zig").Maintenance(@This());
pub const Store = @import("session/store.zig");
pub const Esp = @import("esp.zig").Esp;
pub const Firmware = firmware.Firmware;
pub const query = @import("inventory.zig").query;
pub fn records(a: std.mem.Allocator) !Store {
    var store: Store = .{ .namespace = .maintenance };
    try store.init(a, try security.identity(a, n.k.GetCurrentProcess()));
    return store;
}
pub fn executable(a: std.mem.Allocator, _: std.Io) ![]const u8 {
    return std.unicode.utf16LeToUtf8Alloc(a, try security.executable(a, n.k.GetCurrentProcess()));
}
pub fn openFirmware(_: std.Io, writable: bool) !Firmware {
    return Firmware.open(writable);
}
pub fn closeFirmware(_: *Firmware, _: std.Io) void {}
pub fn requireUnsigned(fw: *Firmware, a: std.mem.Allocator, _: std.Io) !void {
    switch (try fw.secureBoot(a)) {
        .disabled, .unsupported => {},
        .enabled, .unknown => return error.SignedMaintenanceImageRequired,
    }
}
pub fn verifyDisk(a: std.mem.Allocator, _: std.Io, disk: proto.wire.HostDisk) !void {
    const handle = try n.open(a, disk.path, n.GENERIC_READ);
    defer n.close(handle);
    const actual = try n.maintenanceIdentity(a, handle) orelse return error.NonPortableDeviceIdentity;
    if (!std.mem.eql(u8, &actual, &try proto.hexDigest(disk.identity orelse return error.MissingDiskIdentity))) return error.DeviceIdentityChanged;
}
pub fn reboot(_: std.mem.Allocator, _: std.Io) !void {
    try firmware.reboot();
}
