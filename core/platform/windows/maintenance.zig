//! Windows ports for the common maintenance controller.
const std = @import("std");
const proto = @import("proto");
const native = @import("native.zig");
const security = @import("ipc/security.zig");
pub const Maintenance = @import("../../boot/maintenance.zig").Maintenance(@This());
pub const Store = @import("ipc/store.zig");
pub const Esp = @import("esp.zig").Esp;
pub const Uefi = @import("uefi.zig").Uefi;
pub const power = @import("power.zig");
pub const inventory = @import("inventory.zig");

pub fn executable(a: std.mem.Allocator, _: std.Io) ![]const u8 {
    return std.unicode.utf16LeToUtf8Alloc(a, try security.executable(a, native.kernel32.GetCurrentProcess()));
}

pub fn requireUnsigned(fw: *Uefi, a: std.mem.Allocator, _: std.Io) !void {
    switch (try fw.secureBoot(a)) {
        .disabled, .unsupported => {},
        .enabled, .unknown => return error.SignedMaintenanceImageRequired,
    }
}

pub fn verifyDisk(a: std.mem.Allocator, _: std.Io, disk: proto.wire.HostDisk) !void {
    const handle = try native.open(a, disk.path, native.GENERIC_READ);
    defer _ = native.kernel32.CloseHandle(handle);
    const actual = try native.maintenanceIdentity(a, handle) orelse return error.NonPortableDeviceIdentity;
    if (!std.mem.eql(u8, &actual, &try proto.hexDigest(disk.identity orelse return error.MissingDiskIdentity))) return error.DeviceIdentityChanged;
}
