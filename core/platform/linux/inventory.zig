//! Typed Linux inventory. System libraries supply probes, not application JSON.
const std = @import("std");
const libc = @import("libc");
const bd = @import("libblockdev");
const blkid = @import("libblkid");
const devices = @import("device.zig");
const proto = @import("proto");
const wire = proto.wire;
/// Linux sysfs start/size are always expressed in 512-byte units, regardless
/// of the device logical sector size. This is a kernel ABI unit.
const SYSFS_SECTOR_BYTES = 512;

fn stringView(value: [*c]const u8) ?[]const u8 {
    return if (value == null) null else std.mem.span(value);
}

fn takeString(a: std.mem.Allocator, value: [*c]u8) !?[]const u8 {
    defer bd.g_free(value);
    return if (stringView(value)) |text_value| try a.dupe(u8, text_value) else null;
}

test "utility names own their bytes after releasing the GLib allocation" {
    const source = bd.g_strdup("resize2fs");
    if (source == null) return error.OutOfMemory;
    const owned = (try takeString(std.testing.allocator, source)).?;
    defer std.testing.allocator.free(owned);
    try std.testing.expect(@intFromPtr(owned.ptr) != @intFromPtr(source));
    try std.testing.expectEqualStrings("resize2fs", owned);
    try std.testing.expectEqual(@as(?[]const u8, null), try takeString(std.testing.allocator, null));
}

/// Returns caller-owned, trimmed text, or null when the file contains only whitespace.
fn readU8File(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, relative_path: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(allocator, &.{ directory, relative_path });
    defer allocator.free(path);
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    // sysfs and procfs sizes do not reliably describe their readable contents.
    var reader = file.readerStreaming(io, &.{});
    const contents = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(contents);
    const trimmed = std.mem.trim(u8, contents, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else try allocator.dupe(u8, trimmed);
}

test "file text is owned, trimmed, nonempty, and bounded" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);

    try std.testing.expectError(error.FileNotFound, readU8File(allocator, io, directory, "missing"));
    for ([_][]const u8{ "", " \t\r\n", " \t42\r\n", "invalid" }) |input| {
        try temp.dir.writeFile(io, .{ .sub_path = "value", .data = input });
        const text_value = try readU8File(allocator, io, directory, "value");
        defer if (text_value) |value| allocator.free(value);
        if (std.mem.trim(u8, input, &std.ascii.whitespace).len == 0) {
            try std.testing.expectEqual(null, text_value);
        } else {
            try std.testing.expectEqualStrings(std.mem.trim(u8, input, &std.ascii.whitespace), text_value.?);
        }
    }

    const contents = try allocator.alloc(u8, 1024 * 1024 + 1);
    defer allocator.free(contents);
    @memset(contents, 'x');
    try temp.dir.writeFile(io, .{ .sub_path = "value", .data = contents[0 .. contents.len - 1] });
    const at_limit = (try readU8File(allocator, io, directory, "value")).?;
    defer allocator.free(at_limit);
    try std.testing.expectEqual(contents.len - 1, at_limit.len);
    try temp.dir.writeFile(io, .{ .sub_path = "value", .data = contents });
    try std.testing.expectError(error.StreamTooLong, readU8File(allocator, io, directory, "value"));
}

test "file text reads procfs contents even when stat reports size zero" {
    const value = (try readU8File(std.testing.allocator, std.testing.io, "/proc/sys/kernel/random", "boot_id")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqual(@as(usize, 36), value.len);
}

fn physicalId(device: anytype) !?[32]u8 {
    return readPhysicalId(device) catch |err| switch (err) {
        error.MissingWwid, error.EmptyWwid, error.NoDevice, error.NonPortableDeviceIdentity => {
            std.log.warn("Skipping {s}: no usable WWID ({s})", .{ try device.devname(), @errorName(err) });
            return null;
        },
        else => return err,
    };
}

fn readPhysicalId(device: anytype) ![32]u8 {
    if (std.mem.indexOf(u8, try device.syspath(), "/virtual/") != null) return error.MissingWwid;
    // Only an absent WWID permits checking the immediate parent (SCSI).
    // ENXIO means no identity evidence; never substitute another identity source.
    const wwid = (try device.attribute("wwid")) orelse blk: {
        const parent = (try device.parent()) orelse return error.MissingWwid;
        break :blk (try parent.attribute("wwid")) orelse return error.MissingWwid;
    };
    if (wwid.len == 0) return error.EmptyWwid;
    return try identityFromWwid(wwid);
}

fn identityFromWwid(wwid: []const u8) ![32]u8 {
    if (std.mem.startsWith(u8, wwid, "naa.") or std.mem.startsWith(u8, wwid, "eui."))
        return @import("../../planning/identity.zig").diskFromWwid(wwid);
    // Keep the existing digest for other kernel WWID formats, including NVMe
    // UUIDs and the kernel's VID/serial/model/NSID representation.
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("pizza-physical-identity-v1\x00");
    hash.update("wwid\x00");
    hash.update(wwid);
    const raw = hash.finalResult();
    hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&raw);
    hash.update("disk");
    return hash.finalResult();
}

const IdentityFixture = struct {
    value: ?[]const u8 = null,
    parent_value: ?[]const u8 = null,
    failure: ?anyerror = null,
    fn syspath(_: @This()) ![]const u8 {
        return "/sys/devices/test/block/disk";
    }
    fn devname(_: @This()) ![:0]const u8 {
        return "/dev/test-disk";
    }
    fn attribute(self: @This(), _: [:0]const u8) !?[]const u8 {
        if (self.failure) |err| return err;
        return self.value;
    }
    fn parent(self: @This()) !?@This() {
        return .{ .value = self.parent_value };
    }
};

test "physical identity accepts WWID and skips devices without usable identity" {
    const wwid = "naa.6001405abcdef012";
    const expected = try @import("../../planning/identity.zig").diskFromWwid(wwid);
    try std.testing.expectEqual(expected, (try physicalId(IdentityFixture{ .value = wwid })).?);
    try std.testing.expectEqual(expected, (try physicalId(IdentityFixture{ .parent_value = wwid })).?);
    try std.testing.expect((try physicalId(IdentityFixture{})) == null);
    try std.testing.expect((try physicalId(IdentityFixture{ .value = "", .parent_value = wwid })) == null);
    try std.testing.expect((try physicalId(IdentityFixture{ .failure = error.NoDevice, .parent_value = wwid })) == null);
    try std.testing.expect((try physicalId(IdentityFixture{ .value = "naa.invalid", .parent_value = wwid })) == null);
    // An identity problem on one device must not prevent discovering the next.
    try std.testing.expectEqual(expected, (try physicalId(IdentityFixture{ .value = wwid })).?);
    try std.testing.expectError(error.OutOfMemory, physicalId(IdentityFixture{ .failure = error.OutOfMemory }));
    try std.testing.expectError(error.AccessDenied, physicalId(IdentityFixture{ .failure = error.AccessDenied }));
    try std.testing.expectError(error.InputOutput, physicalId(IdentityFixture{ .failure = error.InputOutput }));
}

test "kernel NVMe WWID formats preserve their existing disk identities" {
    const cases = .{
        .{ "uuid.00112233-4455-6677-8899-aabbccddeeff", "845cbf669dfe8c6412eb4de7e9b6bc4c5224f317bb2eea421a7333ae3bc3ff2c" },
        .{ "nvme.1234-534e303031-4d4f44454c-00000001", "6ed33ff9d97d2b5770a7b65bd81fe29978223119bfa0d8018c3ac2ac5ff57736" },
    };
    inline for (cases) |case| {
        const id = try identityFromWwid(case[0]);
        try std.testing.expectEqualStrings(case[1], &std.fmt.bytesToHex(id, .lower));
    }
}

fn partitionId(a: std.mem.Allocator, disk_id: [32]u8, uuid: []const u8) !?[]const u8 {
    const identity = @import("../../planning/identity.zig");
    const raw = (if (uuid.len == 32) identity.guid(uuid) else identity.parseGuid(uuid)) catch return null;
    return try identity.partition(a, &std.fmt.bytesToHex(disk_id, .lower), &std.fmt.bytesToHex(raw, .lower));
}

fn probe(a: std.mem.Allocator, path: [:0]const u8, key: [:0]const u8) !?[]const u8 {
    const p = blkid.blkid_new_probe_from_filename(path) orelse return error.FilesystemProbeFailed;
    defer blkid.blkid_free_probe(p);
    var value: [*c]const u8 = null;
    var length: usize = 0;
    const status = blkid.blkid_do_safeprobe(p);
    if (status == 1) return null;
    if (status != 0) return error.FilesystemProbeFailed;
    if (blkid.blkid_probe_lookup_value(p, key, &value, &length) != 0) return null;
    return try a.dupe(u8, std.mem.sliceTo(value[0..length], 0));
}

const Mounts = struct {
    paths: []const []const u8 = &.{},
    protected: bool = false,
    used: ?u64 = null,
    available: ?u64 = null,
};

fn mounts(a: std.mem.Allocator, io: std.Io, path: []const u8) !Mounts {
    var result: Mounts = .{};
    const data = (readU8File(a, io, "/proc/self", "mountinfo") catch |read_error| if (read_error == error.FileNotFound) null else return read_error) orelse return result;
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, path, a) catch path;
    var paths: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const sep = std.mem.indexOf(u8, line, " - ") orelse continue;
        var fields = std.mem.tokenizeScalar(u8, line[0..sep], ' ');
        for (0..4) |_| _ = fields.next() orelse break;
        const mount = fields.next() orelse continue;
        var source_fields = std.mem.tokenizeScalar(u8, line[sep + 3 ..], ' ');
        _ = source_fields.next() orelse continue;
        const source = source_fields.next() orelse continue;
        const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, source, a) catch source;
        if (!std.mem.eql(u8, real, resolved)) continue;
        try paths.append(a, mount);
        if (std.mem.eql(u8, mount, "/boot/efi") or std.mem.eql(u8, mount, "/efi")) result.protected = true;
        var stats: libc.struct_statvfs = undefined;
        if (libc.statvfs(try a.dupeSentinel(u8, mount, 0), &stats) == 0) {
            result.used = (stats.f_blocks - stats.f_bfree) * stats.f_frsize;
            result.available = stats.f_bavail * stats.f_frsize;
        }
    }
    result.paths = try paths.toOwnedSlice(a);
    return result;
}

fn capability(operation: wire.IntentKind, ok: bool, reason: []const u8, utility: ?[]const u8, mode: bd.BDFSResizeFlags) wire.HostCapability {
    return .{
        .operation = operation,
        .backend = .host,
        .support = if (ok) .available else .unavailable,
        .reason = reason,
        .required_utility = utility,
        .grow = mode & (bd.BD_FS_OFFLINE_GROW | bd.BD_FS_ONLINE_GROW) != 0,
        .shrink = mode & (bd.BD_FS_OFFLINE_SHRINK | bd.BD_FS_ONLINE_SHRINK) != 0,
    };
}

fn tableName(kind: bd.BDPartTableType) ?[]const u8 {
    return switch (kind) {
        bd.BD_PART_TABLE_GPT => "gpt",
        bd.BD_PART_TABLE_MSDOS => "mbr",
        else => null,
    };
}

fn wireGuid(a: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    const text_value = text orelse return null;
    const raw = @import("../../planning/identity.zig").parseGuid(text_value) catch return null;
    return try a.dupe(u8, &std.fmt.bytesToHex(raw, .lower));
}

fn partition(a: std.mem.Allocator, io: std.Io, disk_id: ?[32]u8, p: bd.BDPartSpec, device: ?devices.Device) !wire.HostPartition {
    const path = try a.dupeSentinel(u8, std.mem.span(p.path), 0);
    const uuid = try wireGuid(a, stringView(p.uuid));
    const type_guid = try wireGuid(a, stringView(p.type_guid));

    var probe_failed = false;
    const fs = probe(a, path, "TYPE") catch |err| blk: {
        if (err != error.FilesystemProbeFailed) return err;
        probe_failed = true;
        break :blk if (device) |d| try d.property("ID_FS_TYPE") else null;
    };
    const label = if (probe_failed) (if (device) |d| try d.property("ID_FS_LABEL") else null) else try probe(a, path, "LABEL");
    const mount = try mounts(a, io, path);
    const protected = probe_failed or mount.protected or (inUse(a, io, path) catch true) or (if (type_guid) |v| std.mem.eql(u8, v, &@import("../../planning/identity.zig").Gpt.ESP) else false);
    const mounted = mount.paths.len != 0;
    const kind = if (fs) |v| std.meta.stringToEnum(wire.FilesystemKind, v) else null;
    const partition_number: ?u64 = if (device) |d| try d.number("partition") else null;
    const slot = if (partition_number) |value| blk: {
        if (value == 0) return error.InvalidPartitionNumber;
        break :blk std.math.cast(u32, value - 1) orelse return error.InvalidPartitionNumber;
    } else null;

    var result: wire.HostPartition = .{
        .id = if (disk_id) |id| (if (uuid) |u| try partitionId(a, id, u) else null) orelse path else path,
        .path = path,
        // The plan's name is a filesystem label. GPT names and device paths
        // must not become labels when a volume is subsequently formatted.
        .name = if (label) |v| try a.dupe(u8, v) else "",
        .offset = try a.print("{d}", .{p.start}),
        .length = try a.print("{d}", .{p.size}),
        .encryption = if (fs) |v| (if (std.mem.eql(u8, v, "crypto_LUKS")) .encrypted else .none) else .unknown,
        .filesystem = if (kind) |v| switch (v) {
            .ext2, .ext3, .ext4, .xfs, .btrfs, .vfat, .ntfs, .exfat => v,
            else => null,
        } else null,
        .partition_uuid = uuid,
        .type_guid = type_guid,
        .attributes = try a.print("{d}", .{p.attrs}),
        .slot = slot,
        .protected = protected,
        .mountpoints = mount.paths,
        .used_bytes = if (mount.used) |n| try a.print("{d}", .{n}) else null,
        .free_bytes = if (mount.available) |n| try a.print("{d}", .{n}) else null,
    };
    const caps = try a.alloc(wire.HostCapability, 5);
    var err: [*c]bd.GError = null;
    defer bd.g_clear_error(&err);
    var utility: [*c]u8 = null;
    var mode: bd.BDFSResizeFlags = 0;
    const fs_z: ?[:0]const u8 = if (fs) |value| try a.dupeSentinel(u8, value, 0) else null;
    var ok = if (fs_z) |f| bd.bd_fs_can_resize(f, &mode, &utility, &err) != 0 else false;
    bd.g_clear_error(&err);
    mode &= if (mounted) bd.BD_FS_ONLINE_GROW else bd.BD_FS_OFFLINE_GROW | bd.BD_FS_OFFLINE_SHRINK;
    if (!mounted and fs != null and (std.mem.eql(u8, fs.?, "btrfs") or std.mem.eql(u8, fs.?, "xfs"))) mode = 0;
    caps[0] = capability(.resize, !protected and ok and mode != 0, "filesystem_and_volume_validation_required", try takeString(a, utility), mode);
    utility = null;
    ok = if (fs_z) |f| bd.bd_fs_can_set_label(f, &utility, &err) != 0 else false;
    bd.g_clear_error(&err);
    caps[1] = capability(.label, !protected and ok, "filesystem_label", try takeString(a, utility), 0);
    caps[2] = capability(.delete, !protected and !mounted, "unmounted_partition_required", null, 0);
    caps[3] = capability(.format, !protected and !mounted, "filesystem_tool_required", null, 0);
    caps[4] = capability(.move, false, "maintenance_required", null, 0);
    result.capabilities = caps;
    return result;
}
fn deviceParts(a: std.mem.Allocator, io: std.Io, device: devices.Device, id: ?[32]u8) ![]const wire.HostPartition {
    var enumerator = try devices.Enumerator.init("partition", device);
    defer enumerator.deinit();
    var result: std.ArrayList(wire.HostPartition) = .empty;
    while (enumerator.next()) |child| {
        const owner = (try child.parent()) orelse return error.MissingPartitionParent;
        if (!std.mem.eql(u8, try owner.syspath(), try device.syspath())) continue;
        var p: bd.BDPartSpec = std.mem.zeroes(bd.BDPartSpec);
        p.path = @constCast((try child.devname()).ptr);
        p.start = try std.math.mul(u64, try child.number("start"), SYSFS_SECTOR_BYTES);
        p.size = try std.math.mul(u64, try child.number("size"), SYSFS_SECTOR_BYTES);
        p.uuid = if (try child.property("ID_PART_ENTRY_UUID")) |u| try a.dupeSentinel(u8, u, 0) else null;
        p.type_guid = if (try child.property("ID_PART_ENTRY_TYPE")) |u| try a.dupeSentinel(u8, u, 0) else null;
        try result.append(a, try partition(a, io, id, p, child));
    }
    return result.toOwnedSlice(a);
}

fn disk(a: std.mem.Allocator, io: std.Io, device: devices.Device) !?wire.HostDisk {
    const size = try std.math.mul(u64, try device.number("size"), SYSFS_SECTOR_BYTES);
    if (size == 0) return null;
    const id = (try physicalId(device)) orelse return null;
    const path = try a.dupeSentinel(u8, try device.devname(), 0);
    const sector = try device.number("queue/logical_block_size");
    if (sector == 0) return error.InvalidSectorSize;
    const model = (try device.attribute("model")) orelse blk: {
        const parent = (try device.parent()) orelse break :blk null;
        break :blk try parent.attribute("model");
    };
    var result: wire.HostDisk = .{
        .path = path,
        .identity = try a.dupe(u8, &std.fmt.bytesToHex(id, .lower)),
        .model = try a.dupe(u8, model orelse try device.sysname()),
        .capacity = try a.print("{d}", .{size}),
        .sector_size = std.math.cast(u32, sector) orelse return error.InvalidSectorSize,
        .read_only = (try device.number("ro")) != 0,
    };
    var err: [*c]bd.GError = null;
    defer bd.g_clear_error(&err);
    const spec = bd.bd_part_get_disk_spec(path, &err);
    bd.g_clear_error(&err);
    if (spec != null) {
        defer bd.bd_part_disk_spec_free(spec);
        result.partition_table = tableName(spec.*.table_type);
        if (spec.*.table_type == bd.BD_PART_TABLE_GPT) blk: {
            const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch break :blk;
            defer file.close(io);
            var header: [92]u8 = undefined;
            if ((file.readPositionalAll(io, &header, result.sector_size) catch break :blk) != header.len or !std.mem.eql(u8, header[0..8], "EFI PART")) break :blk;
            const first = std.mem.readInt(u64, header[40..48], .little);
            const last = std.mem.readInt(u64, header[48..56], .little);
            if (last >= first and last < size / result.sector_size) {
                result.usable_offset = try a.print("{d}", .{first * result.sector_size});
                result.usable_length = try a.print("{d}", .{(last - first + 1) * result.sector_size});
            }
        }
    }
    const parts = bd.bd_part_get_disk_parts(path, &err);
    bd.g_clear_error(&err);
    if (parts == null) {
        result.partitions = try deviceParts(a, io, device, id);
    } else {
        defer {
            var i: usize = 0;
            while (parts[i] != null) : (i += 1) bd.bd_part_spec_free(parts[i]);
            bd.g_free(@ptrCast(parts));
        }
        var list: std.ArrayList(wire.HostPartition) = .empty;
        var i: usize = 0;
        while (parts[i] != null) : (i += 1) {
            const child = try devices.Device.fromDevname(std.mem.span(parts[i].*.path));
            defer child.deinit();
            try list.append(a, try partition(a, io, id, parts[i].*, child));
        }
        result.partitions = try list.toOwnedSlice(a);
    }
    return result;
}

pub fn query(a: std.mem.Allocator, io: std.Io) !wire.InventorySnapshot {
    try @import("blockdev.zig").init();
    var enumerator = try devices.Enumerator.init("disk", null);
    defer enumerator.deinit();
    var disks: std.ArrayList(wire.HostDisk) = .empty;
    while (enumerator.next()) |device| if (try disk(a, io, device)) |value| {
        for (disks.items) |previous| if (value.identity != null and previous.identity != null and std.mem.eql(u8, value.identity.?, previous.identity.?)) return error.AmbiguousDiskIdentity;
        try disks.append(a, value);
    };
    std.mem.sort(wire.HostDisk, disks.items, {}, struct {
        fn less(_: void, left: wire.HostDisk, right: wire.HostDisk) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.less);
    var result: wire.InventorySnapshot = .{ .version = proto.API_VERSION, .platform = .linux, .snapshot_id = "", .disks = try disks.toOwnedSlice(a) };
    result.snapshot_id = try @import("../../planning/identity.zig").fingerprint(a, result);
    return result;
}

test "partition identity matches the protocol GPT byte order" {
    const a = std.testing.allocator;
    const id = try partitionId(a, @splat(0xab), "c12a7328-f81f-11d2-ba4b-00a0c93ec93b");
    defer a.free(id.?);
    const expected = try @import("../../planning/identity.zig").partition(
        a,
        "abababababababababababababababababababababababababababababababab",
        "28732ac11ff8d211ba4b00a0c93ec93b",
    );
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, id.?);
}

test "filesystem label round-trip never substitutes the GPT name or device path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(io, "volume.img", .{ .exclusive = true });
    defer file.close(io);
    try file.setLength(io, 64 * 1024 * 1024);
    const path = try temp.dir.realPathFileAlloc(io, "volume.img", a);
    const blockdev = @import("blockdev.zig");
    try blockdev.perform(.{ .disk = path, .part = path, .kind = .format, .filesystem = "ext4" });
    var random: [4]u8 = undefined;
    io.random(&random);
    const label = try a.dupeSentinel(u8, &std.fmt.bytesToHex(random, .lower), 0);
    var spec: bd.BDPartSpec = std.mem.zeroes(bd.BDPartSpec);
    spec.path = @constCast(path.ptr);
    spec.name = @constCast(label.ptr); // An actual, different GPT name is present.
    spec.size = try file.length(io);
    for ([_][:0]const u8{ "", label, "" }, 0..) |expected, i| {
        if (i != 0) try blockdev.perform(.{ .disk = path, .part = path, .kind = .label, .filesystem = "ext4", .label = expected });
        const actual = try partition(a, io, null, spec, null);
        try std.testing.expectEqualStrings(expected, actual.name);
        try std.testing.expectEqualStrings(path, actual.path.?);
    }
}

test "Linux discovery normalizes provider GUIDs and leaves an unpartitioned disk untyped" {
    const a = std.testing.allocator;
    const uuid = (try wireGuid(a, "C12A7328-F81F-11D2-BA4B-00A0C93EC93B")).?;
    defer a.free(uuid);
    try std.testing.expectEqualStrings(&@import("../../planning/identity.zig").Gpt.ESP, uuid);
    try std.testing.expect((try wireGuid(a, "not-a-GPT-UUID")) == null);
    try std.testing.expect(tableName(bd.BD_PART_TABLE_UNDEF) == null);
    try std.testing.expectEqualStrings("mbr", tableName(bd.BD_PART_TABLE_MSDOS).?);
    try std.testing.expectEqualStrings("gpt", tableName(bd.BD_PART_TABLE_GPT).?);
}

/// Mount sources alone omit block-device consumers and secondary btrfs members.
/// Sysfs holders covers device-mapper (LVM/crypt) and MD; swap is listed separately.
pub fn inUse(a: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const real = try std.Io.Dir.cwd().realPathFileAlloc(io, path, a);
    var st: libc.struct_stat = undefined;
    if (libc.stat(try a.dupeSentinel(u8, real, 0), &st) != 0) return error.DeviceUnavailable;
    if (st.st_mode & libc.S_IFMT == libc.S_IFREG) return false;
    if (st.st_mode & libc.S_IFMT != libc.S_IFBLK) return error.BlockDeviceRequired;
    const base = std.fs.path.basename(real);
    var holders = try std.Io.Dir.cwd().openDir(io, try a.print("/sys/class/block/{s}/holders", .{base}), .{ .iterate = true });
    defer holders.close(io);
    var entries = holders.iterate();
    if (try entries.next(io) != null) return true;
    const swaps = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/swaps", a, .limited(1024 * 1024));
    var lines = std.mem.splitScalar(u8, swaps, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const source = fields.next() orelse continue;
        // Kernel proc paths use octal escapes, just as mountinfo does.
        const decoded = try decodeProcPath(a, source);
        const resolved = try std.Io.Dir.cwd().realPathFileAlloc(io, decoded, a);
        if (std.mem.eql(u8, real, resolved)) return true;
    }
    const dev = (try readU8File(a, io, try a.print("/sys/class/block/{s}", .{base}), "dev")) orelse return error.MissingBlockDeviceNumber;
    var btrfs = std.Io.Dir.cwd().openDir(io, "/sys/fs/btrfs", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer btrfs.close(io);
    var filesystems = btrfs.iterate();
    while (try filesystems.next(io)) |entry| {
        if (entry.kind != .directory or std.mem.eql(u8, entry.name, "features")) continue;
        const directory = try a.print("/sys/fs/btrfs/{s}/devices", .{entry.name});
        var members = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
        defer members.close(io);
        var devices_it = members.iterate();
        while (try devices_it.next(io)) |member| {
            const member_dev = try readU8File(a, io, try a.print("{s}/{s}", .{ directory, member.name }), "dev");
            if (member_dev) |value| if (std.mem.eql(u8, value, dev)) return true;
        }
    }
    return false;
}
fn decodeProcPath(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\\') {
            if (source.len - i < 4) return error.InvalidProcPath;
            const value = std.fmt.parseInt(u8, source[i + 1 ..][0..3], 8) catch return error.InvalidProcPath;
            if (value == 0) return error.InvalidProcPath;
            try result.append(a, value);
            i += 4;
        } else {
            try result.append(a, source[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(a);
}
test "swap paths decode kernel octal escapes without accepting malformed paths" {
    const a = std.testing.allocator;
    const path = try decodeProcPath(a, "/dev/a\\040b");
    defer a.free(path);
    try std.testing.expectEqualStrings("/dev/a b", path);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidProcPath, decodeProcPath(arena.allocator(), "/dev/\\00"));
}
