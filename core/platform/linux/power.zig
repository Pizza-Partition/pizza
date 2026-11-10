//! Linux system power operations.
const std = @import("std");

pub fn reboot(a: std.mem.Allocator, io: std.Io) !void {
    // Ask PID 1 to stop services and unmount filesystems normally.
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("PATH", "/usr/sbin:/usr/bin:/sbin:/bin");
    const result = try std.process.run(a, io, .{ .environ_map = &env, .argv = &.{ "/usr/bin/systemctl", "--no-block", "reboot" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) });
    if (!result.term.success()) return error.RebootFailed;
}
