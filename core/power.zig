//! The caller must establish PID1 and durability preconditions first.
const std = @import("std");

/// Requests Linux poweroff only when running as PID 1.
/// The caller must establish durability first; returns NotPid1 or PoweroffFailed on refusal or failure.
pub fn poweroff() error{ NotPid1, PoweroffFailed }!void {
    if (std.os.linux.getpid() != 1)
        return error.NotPid1;
    const result = std.os.linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
    if (std.os.linux.errno(result) != .SUCCESS)
        return error.PoweroffFailed;
}
