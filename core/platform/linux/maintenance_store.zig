//! Root-owned, serialized maintenance state, independent of the UI user's runs.
const Self = @This();
const std = @import("std");
const libc = @import("libc");
const security = @import("ipc/store.zig");
dir: c_int,
lock: c_int,
const MAX = 8 * 1024 * 1024;
pub fn openMaintenance(_: std.mem.Allocator) !Self {
    if (libc.geteuid() != 0) return error.FirmwareRequiresRoot;
    if (!security.directory("/var/lib/pizza", 0o700) or !security.directory("/var/lib/pizza/maintenance", 0o700)) return error.UnsafeMaintenanceDirectory;
    const dir = libc.open("/var/lib/pizza/maintenance", libc.O_RDONLY | libc.O_DIRECTORY | libc.O_CLOEXEC | libc.O_NOFOLLOW);
    if (dir < 0) return error.MaintenanceStoreUnavailable;
    errdefer _ = libc.close(dir);
    const lock = libc.openat(dir, "lock", libc.O_CREAT | libc.O_RDWR | libc.O_CLOEXEC | libc.O_NOFOLLOW, @as(libc.mode_t, 0o600));
    if (lock < 0) return error.MaintenanceStoreUnavailable;
    errdefer _ = libc.close(lock);
    var st: libc.struct_stat = undefined;
    if (libc.fstat(lock, &st) != 0 or !security.regular(st, 0) or st.st_nlink != 1) return error.UnsafeMaintenanceRecord;
    if (libc.flock(lock, libc.LOCK_EX | libc.LOCK_NB) != 0) return error.MaintenanceBusy;
    return .{ .dir = dir, .lock = lock };
}
pub fn deinit(self: *Self) void {
    _ = libc.close(self.lock);
    _ = libc.close(self.dir);
}
pub fn read(self: *Self, a: std.mem.Allocator) !?[]const u8 {
    return readAt(a, self.dir, 0);
}
fn readAt(a: std.mem.Allocator, dir: c_int, uid: libc.uid_t) !?[]const u8 {
    return security.readFile(a, dir, "pending.json", uid, recordPolicy) catch |err| return switch (err) {
        error.SessionRecordUnavailable => error.MaintenanceRecordUnavailable,
        error.UnsafeSessionRecord => error.UnsafeMaintenanceRecord,
        error.SessionRecordReadFailed => error.MaintenanceRecordReadFailed,
        else => err,
    };
}
fn recordPolicy(st: libc.struct_stat) bool {
    return st.st_nlink == 1 and st.st_size > 0 and st.st_size <= MAX;
}

pub fn persist(self: *Self, bytes: []const u8) !void {
    try persistAt(self.dir, bytes);
}
fn persistAt(dir: c_int, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > MAX) return error.InvalidMaintenanceRecord;
    security.replaceFile(dir, "pending.json", bytes) catch |err| return switch (err) {
        error.SessionSyncFailed => error.MaintenanceRecordSyncFailed,
        else => err,
    };
}

test "maintenance records survive replacement and reject unsafe persisted input" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const a = std.testing.allocator;
    const dir = libc.openat(temp.dir.handle, ".", libc.O_RDONLY | libc.O_DIRECTORY | libc.O_CLOEXEC);
    try std.testing.expect(dir >= 0);
    defer _ = libc.close(dir);
    try std.testing.expect((try readAt(a, dir, libc.geteuid())) == null);
    try persistAt(dir, "first");
    try persistAt(dir, "second");
    const bytes = (try readAt(a, dir, libc.geteuid())).?;
    defer a.free(bytes);
    try std.testing.expectEqualStrings("second", bytes);
    try std.testing.expectError(error.UnsafeMaintenanceRecord, readAt(a, dir, libc.geteuid() + 1));
    try std.testing.expectEqual(@as(c_int, 0), libc.linkat(dir, "pending.json", dir, "linked.json", 0));
    try std.testing.expectError(error.UnsafeMaintenanceRecord, readAt(a, dir, libc.geteuid()));
    try std.testing.expectEqual(@as(c_int, 0), libc.unlinkat(dir, "linked.json", 0));
    try security.replaceFile(dir, "pending.json", "");
    try std.testing.expectError(error.UnsafeMaintenanceRecord, readAt(a, dir, libc.geteuid()));
    try persistAt(dir, "second");
    try std.testing.expectEqual(@as(c_int, 0), libc.fchmodat(dir, "pending.json", 0o644, 0));
    try std.testing.expectError(error.UnsafeMaintenanceRecord, readAt(a, dir, libc.geteuid()));
    try std.testing.expectEqual(@as(c_int, 0), libc.unlinkat(dir, "pending.json", 0));
    try std.testing.expectEqual(@as(c_int, 0), libc.symlinkat("/etc/passwd", dir, "pending.json"));
    try std.testing.expectError(error.MaintenanceRecordUnavailable, readAt(a, dir, libc.geteuid()));
    try std.testing.expectError(error.InvalidMaintenanceRecord, persistAt(dir, ""));
}
