//! Build-time modprobe resolves dependencies; PID 1 loads the resulting ordered list.
const std = @import("std");
const linux = std.os.linux;
const fs = @import("utils").filesystem;

/// Loads uncompressed, matching-kernel modules. EEXIST also covers built-in or
/// previously loaded dependencies. Every other error leaves maintenance degraded.
pub fn load(allocator: std.mem.Allocator, io: std.Io) !usize {
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "/etc/pizza/kernel-version", allocator, .limited(256));
    defer allocator.free(expected);
    var identity: linux.utsname = undefined;
    if (linux.errno(linux.uname(&identity)) != .SUCCESS) return error.KernelIdentityUnavailable;
    const running = std.mem.sliceTo(&identity.release, 0);
    if (!std.mem.eql(u8, std.mem.trim(u8, expected, "\r\n"), running)) {
        std.log.err("Kernel mismatch: image={s}, running={s}", .{ std.mem.trim(u8, expected, "\r\n"), running });
        return error.KernelVersionMismatch;
    }
    const list = try std.Io.Dir.cwd().readFileAlloc(io, "/etc/pizza/modules", allocator, .limited(1024 * 1024));
    defer allocator.free(list);
    var lines = std.mem.tokenizeScalar(u8, list, '\n');
    var count: usize = 0;
    while (lines.next()) |path| {
        try validatePath(path);
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const result = linux.syscall3(.finit_module, @intCast(file.handle), @intFromPtr(@as([*:0]const u8, "")), 0);
        switch (linux.errno(result)) {
            .SUCCESS, .EXIST => count += 1,
            else => |err| {
                std.log.err("Module {s}: {t}", .{ path, err });
                return error.ModuleLoadFailed;
            },
        }
    }
    std.log.info("PIZZA_MAINT_MODULES_READY: {d} loadable modules", .{count});
    return count;
}

fn validatePath(path: []const u8) !void {
    const prefix = "/lib/modules/";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, ".ko")) return error.InvalidModulePath;
    try fs.checkPath(path[prefix.len..]);
}

test "module list cannot escape the kernel module tree or contain compressed inputs" {
    try validatePath("/lib/modules/6.1/kernel/fs/ext4/ext4.ko");
    for ([_][]const u8{ "/tmp/evil.ko", "/lib/modules/../evil.ko", "/lib/modules/x//evil.ko", "/lib/modules/x/module.ko.zst" }) |path|
        try std.testing.expectError(if (std.mem.startsWith(u8, path, "/lib/modules/") and std.mem.endsWith(u8, path, ".ko")) error.UnsafePath else error.InvalidModulePath, validatePath(path));
}
