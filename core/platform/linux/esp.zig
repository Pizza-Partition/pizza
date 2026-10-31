//! Private FAT32 mount of the identified ESP. All file access is descriptor-relative.
const std = @import("std");
const c = @import("libc");
const proto = @import("proto");
const boot = @import("../../boot/session.zig");
const staging = @import("../../boot/staging.zig");
const filename = staging.filename;
const limit = staging.limit;
const identity = @import("../../planning/identity.zig");
pub const Esp = struct {
    a: std.mem.Allocator,
    io: std.Io,
    disk_identity: []const u8,
    session_id: boot.Digest,
    uuid: []const u8,
    offset: u64,
    length: u64,
    mountpoint: [:0]const u8,
    disk_fd: c_int,
    part_fd: c_int,
    dir: c_int,

    pub fn open(a: std.mem.Allocator, io: std.Io, disk: proto.wire.HostDisk, part: proto.wire.HostPartition, session: []const u8, create: bool) !Esp {
        if (c.geteuid() != 0) return error.FirmwareRequiresRoot;
        const session_id = try proto.hexDigest(session);
        if (disk.read_only or !std.mem.eql(u8, disk.partition_table orelse "", "gpt") or
            !std.mem.eql(u8, part.type_guid orelse "", &identity.Gpt.ESP) or part.filesystem != .vfat) return error.Fat32EspRequired;
        const disk_fd = c.open(try a.dupeSentinel(u8, disk.path, 0), c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
        if (disk_fd < 0) return error.EspDeviceUnavailable;
        errdefer _ = c.close(disk_fd);
        if (c.flock(disk_fd, c.LOCK_EX | c.LOCK_NB) != 0) return error.DeviceBusy;
        const part_fd = c.open(try a.dupeSentinel(u8, part.path orelse return error.EspDeviceUnavailable, 0), c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
        if (part_fd < 0) return error.EspDeviceUnavailable;
        errdefer _ = c.close(part_fd);
        var st: c.struct_stat = undefined;
        if (c.fstat(part_fd, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFBLK) return error.BlockDeviceRequired;
        var size: u64 = 0;
        if (c.ioctl(part_fd, c.BLKGETSIZE64, &size) != 0 or size != try proto.byteCount(part.length)) return error.EspPartitionChanged;
        // FAT16 must not pass as FAT32 merely because blkid calls both vfat.
        var bpb: [90]u8 = undefined;
        if (c.pread(part_fd, &bpb, bpb.len, 0) != bpb.len or std.mem.readInt(u16, bpb[17..19], .little) != 0 or
            std.mem.readInt(u16, bpb[22..24], .little) != 0 or std.mem.readInt(u32, bpb[36..40], .little) == 0) return error.Fat32EspRequired;
        if (!@import("session/store.zig").directory("/run/pizza-maintenance", 0o700)) return error.UnsafeEspDirectory;
        var random: [16]u8 = undefined;
        io.random(&random);
        const mountpoint = try a.printSentinel("/run/pizza-maintenance/{s}", .{std.fmt.bytesToHex(random, .lower)}, 0);
        if (c.mkdir(mountpoint, 0o700) != 0) return error.EspMountFailed;
        errdefer _ = c.rmdir(mountpoint);
        const source = try a.printSentinel("/proc/self/fd/{d}", .{part_fd}, 0);
        if (c.mount(source, mountpoint, "vfat", c.MS_NODEV | c.MS_NOSUID | c.MS_NOEXEC, "uid=0,gid=0,fmask=0077,dmask=0077") != 0) return switch (c.__errno_location().*) {
            c.ENODEV => error.EspFilesystemUnavailable,
            c.EACCES, c.EPERM => error.EspMountDenied,
            c.EINVAL => error.InvalidEspFilesystem,
            else => error.EspMountFailed,
        };
        errdefer _ = c.umount(mountpoint);
        var dir = c.open(mountpoint, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW);
        if (dir < 0) return error.EspDirectoryUnavailable;
        errdefer _ = c.close(dir);
        try safeDirectory(dir);
        var fs: c.struct_statfs = undefined;
        if (c.fstatfs(dir, &fs) != 0 or fs.f_type != 0x4d44) return error.Fat32EspRequired;
        for (try staging.segments(a, session)) |segment| {
            const name = try a.dupeSentinel(u8, segment, 0);
            if (create and c.mkdirat(dir, name, 0o700) != 0 and c.__errno_location().* != c.EEXIST) return error.EspDirectoryUnavailable;
            const next = c.openat(dir, name, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW);
            if (next < 0) return error.UnsafeEspDirectory;
            safeDirectory(next) catch |err| {
                _ = c.close(next);
                return err;
            };
            _ = c.close(dir);
            dir = next;
        }
        var self: Esp = .{ .a = a, .io = io, .disk_identity = disk.identity orelse return error.MissingDiskIdentity, .session_id = session_id, .uuid = part.partition_uuid orelse return error.MissingPartitionIdentity, .offset = try proto.byteCount(part.offset), .length = size, .mountpoint = mountpoint, .disk_fd = disk_fd, .part_fd = part_fd, .dir = dir };
        try self.verifyMapping();
        if (c.syncfs(dir) != 0) return error.EspSyncFailed;
        return self;
    }
    pub fn close(self: *Esp, _: std.Io) void {
        _ = c.close(self.dir);
        if (c.umount(self.mountpoint) == 0) _ = c.rmdir(self.mountpoint);
        _ = c.close(self.part_fd);
        _ = c.close(self.disk_fd);
    }
    fn verifyMapping(self: *Esp) !void {
        var arena: std.heap.ArenaAllocator = .init(self.a);
        defer arena.deinit();
        const snapshot = try @import("inventory.zig").query(arena.allocator(), self.io);
        const disk = try @import("../../execution/state.zig").disk(snapshot, self.disk_identity);
        var st: c.struct_stat = undefined;
        if (c.fstat(self.disk_fd, &st) != 0) return error.DeviceIdentityChanged;
        var current: c.struct_stat = undefined;
        if (c.stat(try arena.allocator().dupeSentinel(u8, disk.path, 0), &current) != 0 or st.st_rdev != current.st_rdev) return error.DeviceIdentityChanged;
        for (disk.partitions) |p| if (std.mem.eql(u8, p.partition_uuid orelse "", self.uuid)) {
            if (try proto.byteCount(p.offset) != self.offset or try proto.byteCount(p.length) != self.length or
                !std.mem.eql(u8, p.type_guid orelse "", &identity.Gpt.ESP)) return error.EspPartitionChanged;
            if (c.fstat(self.part_fd, &st) != 0 or c.stat(try arena.allocator().dupeSentinel(u8, p.path orelse return error.EspMappingChanged, 0), &current) != 0 or st.st_rdev != current.st_rdev) return error.EspMappingChanged;
            return;
        };
        return error.EspPartitionChanged;
    }
    pub const bootPath = staging.bootPath;
    pub fn store(self: *Esp) boot.Store {
        return .{ .context = self, .read = read, .publish = publish };
    }
    pub fn ensureReserved(self: *Esp, file: boot.File, bytes: u64) !void {
        if (bytes == 0 or bytes > limit(file)) return error.InvalidStageReservation;
        try self.verifyMapping();
        const fd = c.openat(self.dir, filename(file), c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK);
        if (fd < 0) {
            if (c.__errno_location().* != c.ENOENT) return error.StageReservationFailed;
            return self.reserve(file, bytes);
        }
        defer _ = c.close(fd);
        if (try fileSize(fd) != bytes) return error.StageReservationSizeChanged;
    }
    pub fn reserve(self: *Esp, file: boot.File, bytes: u64) !void {
        if (bytes == 0 or bytes > limit(file)) return error.InvalidStageReservation;
        try self.verifyMapping();
        const fd = c.openat(self.dir, filename(file), c.O_CREAT | c.O_EXCL | c.O_WRONLY | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c.mode_t, 0o600));
        if (fd < 0) return error.StageReservationFailed;
        defer _ = c.close(fd);
        const zeros: [65536]u8 = @splat(0);
        var left = bytes;
        while (left != 0) {
            const n: usize = @intCast(@min(left, zeros.len));
            if (!@import("session/transport.zig").writeAll(fd, zeros[0..n])) return error.StageReservationFailed;
            left -= n;
        }
        if (c.fsync(fd) != 0 or c.syncfs(self.dir) != 0) return error.EspSyncFailed;
    }
    fn publish(ctx: *anyopaque, _: std.Io, file: boot.File, bytes: []const u8) !void {
        const self: *Esp = @ptrCast(@alignCast(ctx));
        if (bytes.len == 0 or bytes.len > limit(file)) return error.StagedArtifactTooLarge;
        try self.verifyMapping();
        const fd = c.openat(self.dir, filename(file), c.O_WRONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK);
        if (fd < 0) return error.StageNotReserved;
        defer _ = c.close(fd);
        if (try fileSize(fd) != bytes.len) return error.StageReservationSizeChanged;
        if (!@import("session/transport.zig").writeAll(fd, bytes)) return error.EspWriteFailed;
        if (c.fsync(fd) != 0 or c.syncfs(self.dir) != 0) return error.EspSyncFailed;
    }
    fn read(ctx: *anyopaque, a: std.mem.Allocator, _: std.Io, file: boot.File) !?[]const u8 {
        const self: *Esp = @ptrCast(@alignCast(ctx));
        try self.verifyMapping();
        const fd = c.openat(self.dir, filename(file), c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK);
        if (fd < 0) return if (c.__errno_location().* == c.ENOENT) null else error.StagedArtifactUnavailable;
        defer _ = c.close(fd);
        const size = try fileSize(fd);
        if (size == 0 or size > limit(file)) return error.StagedArtifactTooLarge;
        const bytes = try a.alloc(u8, @intCast(size));
        errdefer a.free(bytes);
        if (!@import("session/transport.zig").readExact(fd, bytes)) return error.StagedArtifactReadFailed;
        return staging.decode(a, file, bytes, self.session_id, try proto.hexDigest(self.disk_identity));
    }
    pub fn releaseReservations(self: *Esp) !void {
        try self.verifyMapping();
        for ([_]boot.File{ .image, .manifest, .anchor }) |file| {
            if (c.unlinkat(self.dir, filename(file), 0) != 0 and c.__errno_location().* != c.ENOENT) return error.EspCleanupFailed;
        }
        if (c.syncfs(self.dir) != 0) return error.EspSyncFailed;
    }
};
fn safeDirectory(fd: c_int) !void {
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFDIR or st.st_uid != 0 or st.st_mode & 0o022 != 0) return error.UnsafeEspDirectory;
}
fn fileSize(fd: c_int) !u64 {
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG or st.st_nlink != 1 or st.st_uid != 0 or st.st_mode & 0o022 != 0 or st.st_size < 0) return error.UnsafeEspFile;
    return @intCast(st.st_size);
}

test "Linux ESP uses the same short-name boot path as the maintenance runtime" {
    const a = std.testing.allocator;
    const path = try Esp.bootPath(a, "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789");
    defer a.free(path);
    try std.testing.expectEqualStrings("\\EFI\\Pizza\\ABCDEF01\\23456789\\ABCDEF01\\23456789\\ABCDEF01\\23456789\\ABCDEF01\\23456789\\maint.efi", path);
    try std.testing.expectError(error.InvalidDeviceIdentity, Esp.bootPath(a, "../bad"));
}
test "Linux ESP refuses invalid allocations before accessing a device" {
    var esp: Esp = undefined;
    try std.testing.expectError(error.InvalidStageReservation, esp.reserve(.image, 0));
    try std.testing.expectError(error.InvalidStageReservation, esp.ensureReserved(.receipt, 2 * 1024 * 1024 + 1));
    const port = esp.store();
    try std.testing.expectError(error.StagedArtifactTooLarge, port.publish(port.context, std.testing.io, .image, ""));
}
