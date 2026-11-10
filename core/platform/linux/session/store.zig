//! Atomic per-user execution records; storage does not depend on active workers.
const Store = @This();
const std = @import("std");
const libc = @import("libc");
const transport = @import("transport.zig");
const validId = @import("../../../execution/worker.zig").validId;
owner: libc.uid_t = 0,
const MAX_RECORD = 4 * 1024 * 1024;

fn sessionDirectory(self: *const Store, buffer: []u8) ![:0]const u8 {
    if (libc.geteuid() != 0 or self.owner == 0) return error.SessionUnavailable;
    const path = try std.mem.printSentinel(buffer, "/var/lib/pizza/runs/{d}", .{self.owner}, 0);
    if (!directory("/var/lib/pizza", 0o700) or !directory("/var/lib/pizza/runs", 0o700) or !directory(path, 0o700)) return error.SessionUnavailable;
    return path;
}
fn openSessions(self: *const Store) !c_int {
    var buffer: [128]u8 = undefined;
    const fd = libc.open(try self.sessionDirectory(&buffer), libc.O_RDONLY | libc.O_DIRECTORY | libc.O_CLOEXEC | libc.O_NOFOLLOW);
    if (fd < 0) return error.SessionUnavailable;
    return fd;
}
fn persistAt(dir: c_int, id: []const u8, json: []const u8) !void {
    if (!validId(id) or json.len > MAX_RECORD) return error.InvalidSession;
    var random: [16]u8 = undefined;
    if (libc.getrandom(&random, random.len, 0) != random.len) return error.RandomUnavailable;
    var name_buffer: [80]u8 = undefined;
    const name = try std.mem.printSentinel(&name_buffer, "{s}.json", .{id}, 0);
    var temp_buffer: [144]u8 = undefined;
    const temp = try std.mem.printSentinel(&temp_buffer, "{s}.{s}.tmp", .{ id, std.fmt.bytesToHex(random, .lower) }, 0);
    const file = libc.openat(dir, temp, libc.O_CREAT | libc.O_EXCL | libc.O_WRONLY | libc.O_CLOEXEC | libc.O_NOFOLLOW, @as(libc.mode_t, 0o600));
    if (file < 0) return error.SessionSyncFailed;
    defer _ = libc.close(file);
    errdefer _ = libc.unlinkat(dir, temp, 0);
    if (!transport.writeAll(file, json) or libc.fsync(file) != 0 or libc.renameat(dir, temp, dir, name) != 0 or libc.fsync(dir) != 0) return error.SessionSyncFailed;
}
pub fn persist(self: *Store, id: []const u8, json: []const u8) !void {
    const dir = try self.openSessions();
    defer _ = libc.close(dir);
    try persistAt(dir, id, json);
}
fn readAt(a: std.mem.Allocator, dir: c_int, id: []const u8, uid: libc.uid_t) !?[]const u8 {
    if (!validId(id)) return error.InvalidSession;
    var name_buffer: [80]u8 = undefined;
    const file = libc.openat(dir, try std.mem.printSentinel(&name_buffer, "{s}.json", .{id}, 0), libc.O_RDONLY | libc.O_CLOEXEC | libc.O_NOFOLLOW | libc.O_NONBLOCK);
    if (file < 0) return if (libc.__errno_location().* == libc.ENOENT) null else error.SessionRecordUnavailable;
    defer _ = libc.close(file);
    var stat: libc.struct_stat = undefined;
    if (libc.fstat(file, &stat) != 0 or !regular(stat, uid) or stat.st_size < 0 or stat.st_size > MAX_RECORD) return error.UnsafeSessionRecord;
    const bytes = try a.alloc(u8, @intCast(stat.st_size));
    if (!transport.readExact(file, bytes)) {
        a.free(bytes);
        return error.SessionRecordReadFailed;
    }
    return bytes;
}
pub fn read(self: *Store, a: std.mem.Allocator, id: []const u8) !?[]const u8 {
    const dir = try self.openSessions();
    defer _ = libc.close(dir);
    return readAt(a, dir, id, 0);
}
pub fn latest(self: *Store, a: std.mem.Allocator) !?[]const u8 {
    var buffer: [128]u8 = undefined;
    const path = self.sessionDirectory(&buffer) catch return null;
    const dir = libc.opendir(path) orelse return null;
    defer _ = libc.closedir(dir);
    var newest: libc.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    var id: [64]u8 = @splat(0);
    var found = false;
    var count: usize = 0;
    while (libc.readdir(dir)) |entry| {
        count += 1;
        if (count >= 100_000) return null;
        const name = std.mem.sliceTo(&entry.*.d_name, 0);
        if (name.len != 69 or !std.mem.endsWith(u8, name, ".json") or !validId(name[0..64])) continue;
        var stat: libc.struct_stat = undefined;
        if (libc.fstatat(libc.dirfd(dir), name.ptr, &stat, libc.AT_SYMLINK_NOFOLLOW) != 0 or !regular(stat, 0)) continue;
        if (stat.st_mtim.tv_sec > newest.tv_sec or stat.st_mtim.tv_sec == newest.tv_sec and (stat.st_mtim.tv_nsec > newest.tv_nsec or stat.st_mtim.tv_nsec == newest.tv_nsec and std.mem.order(u8, name[0..64], &id) == .gt)) {
            newest = stat.st_mtim;
            @memcpy(&id, name[0..64]);
            found = true;
        }
    }
    return if (found) try a.dupe(u8, &id) else null;
}
test "durable session replacement rejects symlinks, public records and invalid IDs" {
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const dir = libc.openat(temp.dir.handle, ".", libc.O_RDONLY | libc.O_DIRECTORY | libc.O_CLOEXEC);
    try std.testing.expect(dir >= 0);
    defer _ = libc.close(dir);
    const first_record = "{\"phase\":\"first\"}";
    try persistAt(dir, id, first_record);
    const first = (try readAt(a, dir, id, libc.geteuid())).?;
    defer a.free(first);
    try std.testing.expectEqualStrings(first_record, first);
    try persistAt(dir, id, "{\"completed\":1}");
    const second = (try readAt(a, dir, id, libc.geteuid())).?;
    defer a.free(second);
    try std.testing.expectEqualStrings("{\"completed\":1}", second);
    const name = id ++ ".json";
    try std.testing.expectEqual(@as(c_int, 0), libc.fchmodat(dir, name, 0o644, 0));
    try std.testing.expectError(error.UnsafeSessionRecord, readAt(a, dir, id, libc.geteuid()));
    try std.testing.expectEqual(@as(c_int, 0), libc.unlinkat(dir, name, 0));
    try std.testing.expectEqual(@as(c_int, 0), libc.symlinkat("/etc/passwd", dir, name));
    try std.testing.expectError(error.SessionRecordUnavailable, readAt(a, dir, id, libc.geteuid()));
    try std.testing.expectError(error.InvalidSession, persistAt(dir, "../outside", "{}"));
}

pub fn directory(path: [:0]const u8, mode: libc.mode_t) bool {
    if (libc.mkdir(path, mode) != 0 and libc.__errno_location().* != libc.EEXIST) return false;
    var stat: libc.struct_stat = undefined;
    return libc.lstat(path, &stat) == 0 and stat.st_mode & libc.S_IFMT == libc.S_IFDIR and stat.st_uid == 0 and stat.st_mode & 0o022 == 0;
}
pub fn regular(stat: libc.struct_stat, uid: libc.uid_t) bool {
    return stat.st_mode & libc.S_IFMT == libc.S_IFREG and stat.st_uid == uid and stat.st_mode & 0o077 == 0;
}
