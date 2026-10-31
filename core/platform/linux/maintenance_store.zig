//! Root-owned, serialized maintenance state, independent of the UI user's runs.
const Self = @This();
const std = @import("std");
const c = @import("libc");
const transport = @import("session/transport.zig");
const security = @import("session/store.zig");
dir: c_int,
lock: c_int,
const MAX = 8 * 1024 * 1024;
pub fn open() !Self {
    if (c.geteuid() != 0) return error.FirmwareRequiresRoot;
    if (!security.directory("/var/lib/pizza", 0o700) or !security.directory("/var/lib/pizza/maintenance", 0o700)) return error.UnsafeMaintenanceDirectory;
    const dir = c.open("/var/lib/pizza/maintenance", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (dir < 0) return error.MaintenanceStoreUnavailable;
    errdefer _ = c.close(dir);
    const lock = c.openat(dir, "lock", c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c.mode_t, 0o600));
    if (lock < 0) return error.MaintenanceStoreUnavailable;
    errdefer _ = c.close(lock);
    var st: c.struct_stat = undefined;
    if (c.fstat(lock, &st) != 0 or !security.regular(st, 0) or st.st_nlink != 1) return error.UnsafeMaintenanceRecord;
    if (c.flock(lock, c.LOCK_EX | c.LOCK_NB) != 0) return error.MaintenanceBusy;
    return .{ .dir = dir, .lock = lock };
}
pub fn deinit(self: *Self) void {
    _ = c.close(self.lock);
    _ = c.close(self.dir);
}
pub fn read(self: *Self, a: std.mem.Allocator, _: []const u8) !?[]const u8 {
    return readAt(a, self.dir, 0);
}
fn readAt(a: std.mem.Allocator, dir: c_int, uid: c.uid_t) !?[]const u8 {
    const fd = c.openat(dir, "pending.json", c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK);
    if (fd < 0) return if (c.__errno_location().* == c.ENOENT) null else error.MaintenanceRecordUnavailable;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or !security.regular(st, uid) or st.st_nlink != 1 or st.st_size <= 0 or st.st_size > MAX) return error.UnsafeMaintenanceRecord;
    const bytes = try a.alloc(u8, @intCast(st.st_size));
    errdefer a.free(bytes);
    if (!transport.readExact(fd, bytes)) return error.MaintenanceRecordReadFailed;
    return bytes;
}
pub fn persist(self: *Self, _: []const u8, bytes: []const u8) !void {
    try persistAt(self.dir, bytes);
}
fn persistAt(dir: c_int, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > MAX) return error.InvalidMaintenanceRecord;
    var random: [16]u8 = undefined;
    if (c.getrandom(&random, random.len, 0) != random.len) return error.RandomUnavailable;
    var buf: [64]u8 = undefined;
    const name = try std.mem.printSentinel(&buf, "{s}.tmp", .{std.fmt.bytesToHex(random, .lower)}, 0);
    const fd = c.openat(dir, name, c.O_CREAT | c.O_EXCL | c.O_WRONLY | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c.mode_t, 0o600));
    if (fd < 0) return error.MaintenanceRecordSyncFailed;
    defer _ = c.close(fd);
    errdefer _ = c.unlinkat(dir, name, 0);
    if (!transport.writeAll(fd, bytes) or c.fsync(fd) != 0 or c.renameat(dir, name, dir, "pending.json") != 0 or c.fsync(dir) != 0) return error.MaintenanceRecordSyncFailed;
}
test "maintenance records survive replacement and reject unsafe persisted input" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const a = std.testing.allocator;
    const dir = c.openat(temp.dir.handle, ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    try std.testing.expect(dir >= 0);
    defer _ = c.close(dir);
    try std.testing.expect((try readAt(a, dir, c.geteuid())) == null);
    try persistAt(dir, "first");
    try persistAt(dir, "second");
    const bytes = (try readAt(a, dir, c.geteuid())).?;
    defer a.free(bytes);
    try std.testing.expectEqualStrings("second", bytes);
    try std.testing.expectEqual(@as(c_int, 0), c.fchmodat(dir, "pending.json", 0o644, 0));
    try std.testing.expectError(error.UnsafeMaintenanceRecord, readAt(a, dir, c.geteuid()));
    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(dir, "pending.json", 0));
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("/etc/passwd", dir, "pending.json"));
    try std.testing.expectError(error.MaintenanceRecordUnavailable, readAt(a, dir, c.geteuid()));
    try std.testing.expectError(error.InvalidMaintenanceRecord, persistAt(dir, ""));
}
