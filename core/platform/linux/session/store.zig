//! Atomic per-user execution records; storage does not depend on active workers.
const Store = @This();
const std = @import("std");
const c = @import("libc");
const transport = @import("transport.zig");
const validId = @import("../../../execution/worker.zig").validId;
owner: c.uid_t = 0,
const MAX_RECORD = 4 * 1024 * 1024;

fn sessionDirectory(self: *const Store, buffer: []u8) ![:0]const u8 {
    if (c.geteuid() != 0 or self.owner == 0) return error.SessionUnavailable;
    const path = try std.mem.printSentinel(buffer, "/var/lib/pizza/runs/{d}", .{self.owner}, 0);
    if (!directory("/var/lib/pizza", 0o700) or !directory("/var/lib/pizza/runs", 0o700) or !directory(path, 0o700)) return error.SessionUnavailable;
    return path;
}
fn openSessions(self: *const Store) !c_int {
    var buffer: [128]u8 = undefined;
    const fd = c.open(try self.sessionDirectory(&buffer), c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (fd < 0) return error.SessionUnavailable;
    return fd;
}
fn persistAt(dir: c_int, id: []const u8, json: []const u8) !void {
    if (!validId(id) or json.len > MAX_RECORD) return error.InvalidSession;
    var random: [16]u8 = undefined;
    if (c.getrandom(&random, random.len, 0) != random.len) return error.RandomUnavailable;
    var name_buffer: [80]u8 = undefined;
    const name = try std.mem.printSentinel(&name_buffer, "{s}.json", .{id}, 0);
    var temp_buffer: [144]u8 = undefined;
    const temp = try std.mem.printSentinel(&temp_buffer, "{s}.{s}.tmp", .{ id, std.fmt.bytesToHex(random, .lower) }, 0);
    const file = c.openat(dir, temp, c.O_CREAT | c.O_EXCL | c.O_WRONLY | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c.mode_t, 0o600));
    if (file < 0) return error.SessionSyncFailed;
    defer _ = c.close(file);
    errdefer _ = c.unlinkat(dir, temp, 0);
    if (!transport.writeAll(file, json) or c.fsync(file) != 0 or c.renameat(dir, temp, dir, name) != 0 or c.fsync(dir) != 0) return error.SessionSyncFailed;
}
pub fn persist(self: *Store, id: []const u8, json: []const u8) !void {
    const dir = try self.openSessions();
    defer _ = c.close(dir);
    try persistAt(dir, id, json);
}
fn readAt(a: std.mem.Allocator, dir: c_int, id: []const u8, uid: c.uid_t) !?[]const u8 {
    if (!validId(id)) return null;
    var name_buffer: [80]u8 = undefined;
    const file = c.openat(dir, try std.mem.printSentinel(&name_buffer, "{s}.json", .{id}, 0), c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (file < 0) return null;
    defer _ = c.close(file);
    var stat: c.struct_stat = undefined;
    if (c.fstat(file, &stat) != 0 or !regular(stat, uid) or stat.st_size < 0 or stat.st_size > MAX_RECORD) return null;
    const bytes = try a.alloc(u8, @intCast(stat.st_size));
    if (!transport.readExact(file, bytes)) {
        a.free(bytes);
        return null;
    }
    return bytes;
}
pub fn read(self: *Store, a: std.mem.Allocator, id: []const u8) !?[]const u8 {
    const dir = self.openSessions() catch return null;
    defer _ = c.close(dir);
    return readAt(a, dir, id, 0);
}
pub fn latest(self: *Store, a: std.mem.Allocator) !?[]const u8 {
    var buffer: [128]u8 = undefined;
    const path = self.sessionDirectory(&buffer) catch return null;
    const dir = c.opendir(path) orelse return null;
    defer _ = c.closedir(dir);
    var newest: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    var id: [64]u8 = @splat(0);
    var found = false;
    var count: usize = 0;
    while (c.readdir(dir)) |entry| {
        count += 1;
        if (count >= 100_000) return null;
        const name = std.mem.sliceTo(&entry.*.d_name, 0);
        if (name.len != 69 or !std.mem.endsWith(u8, name, ".json") or !validId(name[0..64])) continue;
        var stat: c.struct_stat = undefined;
        if (c.fstatat(c.dirfd(dir), name.ptr, &stat, c.AT_SYMLINK_NOFOLLOW) != 0 or !regular(stat, 0)) continue;
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
    const dir = c.openat(temp.dir.handle, ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    try std.testing.expect(dir >= 0);
    defer _ = c.close(dir);
    const first_record = "{\"phase\":\"first\"}";
    try persistAt(dir, id, first_record);
    const first = (try readAt(a, dir, id, c.geteuid())).?;
    defer a.free(first);
    try std.testing.expectEqualStrings(first_record, first);
    try persistAt(dir, id, "{\"completed\":1}");
    const second = (try readAt(a, dir, id, c.geteuid())).?;
    defer a.free(second);
    try std.testing.expectEqualStrings("{\"completed\":1}", second);
    const name = id ++ ".json";
    try std.testing.expectEqual(@as(c_int, 0), c.fchmodat(dir, name, 0o644, 0));
    try std.testing.expect((try readAt(a, dir, id, c.geteuid())) == null);
    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(dir, name, 0));
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("/etc/passwd", dir, name));
    try std.testing.expect((try readAt(a, dir, id, c.geteuid())) == null);
    try std.testing.expectError(error.InvalidSession, persistAt(dir, "../outside", "{}"));
}

pub fn directory(path: [:0]const u8, mode: c.mode_t) bool {
    if (c.mkdir(path, mode) != 0 and c.__errno_location().* != c.EEXIST) return false;
    var stat: c.struct_stat = undefined;
    return c.lstat(path, &stat) == 0 and stat.st_mode & c.S_IFMT == c.S_IFDIR and stat.st_uid == 0 and stat.st_mode & 0o022 == 0;
}
pub fn regular(stat: c.struct_stat, uid: c.uid_t) bool {
    return stat.st_mode & c.S_IFMT == c.S_IFREG and stat.st_uid == uid and stat.st_mode & 0o077 == 0;
}
