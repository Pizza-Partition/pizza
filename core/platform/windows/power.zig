//! Windows system power operations.
const std = @import("std");
const native = @import("native.zig");

/// The coordinator calls this only after the durable handoff and boot lease
/// have been read back. Give applications time to close without forcing them.
pub fn reboot(_: std.mem.Allocator, _: std.Io) !void {
    var privilege = try native.Privilege.enable(.shutdown);
    defer privilege.deinit();
    if (native.win32.advapi32.InitiateSystemShutdownExW(null, null, 30, 0, 1, .{ .MAJOR_APPLICATION = 1, .FLAG_PLANNED = 1 }) == 0)
        return error.RebootRequestFailed;
}
