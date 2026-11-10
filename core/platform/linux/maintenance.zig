//! Linux ports for the common maintenance controller.
const std = @import("std");
const wire = @import("proto").wire;
pub const Maintenance = @import("../../boot/maintenance.zig").Maintenance(@This());
pub const Store = @import("maintenance_store.zig");
pub const Esp = @import("esp.zig").Esp;
pub const Uefi = @import("uefi.zig").Uefi;
pub const power = @import("power.zig");
pub const inventory = @import("inventory.zig");

pub fn executable(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, "/proc/self/exe", a);
}

pub fn requireUnsigned(fw: *Uefi, a: std.mem.Allocator, io: std.Io) !void {
    switch (try fw.secureBoot(a, io)) {
        .disabled => {},
        .enabled, .unsupported, .unknown => return error.SignedMaintenanceImageRequired,
    }
}

pub fn verifyDisk(a: std.mem.Allocator, io: std.Io, disk: wire.HostDisk) !void {
    // Fresh discovery derives the portable identity; ESP admission additionally
    // pins and rechecks the actual disk and partition descriptors under flock.
    const current = try @import("../../execution/state.zig").disk(try inventory.query(a, io), disk.identity orelse return error.MissingDiskIdentity);
    if (!std.mem.eql(u8, current.path, disk.path)) return error.DeviceIdentityChanged;
}
