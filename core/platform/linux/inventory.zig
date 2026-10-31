//! Typed Linux inventory. System libraries supply probes, not application JSON.
const std = @import("std");
const c = @import("libc");
const bd = @import("libblockdev");
const blkid = @import("libblkid");
const proto = @import("proto");
const w = proto.wire;
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

fn readU64File(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, relative_path: []const u8) !?u64 {
    const contents = (try readU8File(allocator, io, directory, relative_path)) orelse return null;
    defer allocator.free(contents);
    return try std.fmt.parseInt(u64, contents, 10);
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

test "numeric files distinguish zero, empty contents, missing files, and invalid values" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);

    try std.testing.expectError(error.FileNotFound, readU64File(allocator, io, directory, "missing"));
    const cases = .{
        .{ "0", @as(?u64, 0) },
        .{ " \t42\r\n", @as(?u64, 42) },
        .{ "18446744073709551615", @as(?u64, std.math.maxInt(u64)) },
        .{ "", @as(?u64, null) },
        .{ " \t\r\n", @as(?u64, null) },
    };
    inline for (cases) |case| {
        try temp.dir.writeFile(io, .{ .sub_path = "value", .data = case[0] });
        try std.testing.expectEqual(case[1], try readU64File(allocator, io, directory, "value"));
    }
    try temp.dir.writeFile(io, .{ .sub_path = "value", .data = "invalid" });
    try std.testing.expectError(error.InvalidCharacter, readU64File(allocator, io, directory, "value"));
    for ([_][]const u8{ "-1", "18446744073709551616" }) |input| {
        try temp.dir.writeFile(io, .{ .sub_path = "value", .data = input });
        try std.testing.expectError(error.Overflow, readU64File(allocator, io, directory, "value"));
    }
}

// Some SCSI transports expose identity attributes but return ENXIO when read.
// Treat unavailable identity evidence as absent and try the next provider.
fn identityText(a: std.mem.Allocator, io: std.Io, directory: []const u8, name: []const u8) !?[]const u8 {
    return readU8File(a, io, directory, name) catch |err| switch (err) {
        error.FileNotFound, error.ReadFailed => null,
        else => return err,
    };
}

fn usbId(a: std.mem.Allocator, io: std.Io, base: []const u8) !?[]const u8 {
    const device = std.Io.Dir.cwd().realPathFileAlloc(io, try std.fs.path.join(a, &.{ base, "device" }), a) catch return null;
    const colon = std.mem.lastIndexOfScalar(u8, device, ':') orelse return null;
    const lun = std.fmt.parseInt(u64, device[colon + 1 ..], 10) catch return null;
    var path = base;
    var interface: ?[]const u8 = null;
    while (std.fs.path.dirname(path)) |parent| {
        path = parent;
        if (std.mem.eql(u8, path, "/sys/devices")) break;
        if (try identityText(a, io, path, "bInterfaceNumber")) |v| interface = v;
        if (try identityText(a, io, path, "idVendor")) |vendor| {
            const product = (try identityText(a, io, path, "idProduct")) orelse return null;
            const serial = (try identityText(a, io, path, "serial")) orelse return null;
            return if (interface) |iface| try a.print("usb:{s}:{s}:{s}:{s}:{d}", .{ vendor, product, serial, iface, lun }) else null;
        }
    }
    return null;
}

fn physicalId(a: std.mem.Allocator, io: std.Io, base: []const u8) !?[32]u8 {
    if (std.mem.indexOf(u8, base, "/virtual/") != null) return null;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("pizza-physical-identity-v1\x00");
    const wwid = (try identityText(a, io, base, "wwid")) orelse (try identityText(a, io, base, "device/wwid"));
    if (wwid) |value| {
        if (std.mem.startsWith(u8, value, "naa.") or std.mem.startsWith(u8, value, "eui."))
            return @import("../../planning/identity.zig").diskFromWwid(value) catch null;
        hash.update("wwid\x00");
        hash.update(value);
    } else {
        const serial = (try identityText(a, io, base, "serial")) orelse (try identityText(a, io, base, "device/serial")) orelse try usbId(a, io, base) orelse return null;
        hash.update("serial\x00");
        hash.update(serial);
        for ([_][]const u8{ "device/vendor", "device/model", "nsid" }) |key| {
            hash.update("\x00");
            hash.update(key);
            hash.update("\x00");
            if (try identityText(a, io, base, key)) |value| hash.update(value);
        }
    }
    const raw = hash.finalResult();
    hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&raw);
    hash.update("disk");
    return hash.finalResult();
}
fn partitionId(a: std.mem.Allocator, disk_id: [32]u8, uuid: []const u8) !?[]const u8 {
    const identity = @import("../../planning/identity.zig");
    const raw = (if (uuid.len == 32) identity.guid(uuid) else identity.parseGuid(uuid)) catch return null;
    return try identity.partition(a, &std.fmt.bytesToHex(disk_id, .lower), &std.fmt.bytesToHex(raw, .lower));
}
fn probe(a: std.mem.Allocator, path: [:0]const u8, key: [:0]const u8) !?[]const u8 {
    const p = blkid.blkid_new_probe_from_filename(path) orelse return null;
    defer blkid.blkid_free_probe(p);
    var value: [*c]const u8 = null;
    var length: usize = 0;
    if (blkid.blkid_do_safeprobe(p) != 0 or blkid.blkid_probe_lookup_value(p, key, &value, &length) != 0) return null;
    return try a.dupe(u8, std.mem.sliceTo(value[0..length], 0));
}
fn property(a: std.mem.Allocator, io: std.Io, sys: []const u8, key: []const u8) !?[]const u8 {
    const device = (readU8File(a, io, sys, "dev") catch |read_error| if (read_error == error.FileNotFound) null else return read_error) orelse return null;
    const data = (readU8File(a, io, "/run/udev/data", try a.print("b{s}", .{device})) catch |read_error| if (read_error == error.FileNotFound) null else return read_error) orelse return null;
    const prefix = try a.print("E:{s}=", .{key});
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    return null;
}
const Mounts = struct { paths: []const []const u8 = &.{}, protected: bool = false, used: ?u64 = null, available: ?u64 = null };
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
        var stats: c.struct_statvfs = undefined;
        if (c.statvfs(try a.dupeSentinel(u8, mount, 0), &stats) == 0) {
            result.used = (stats.f_blocks - stats.f_bfree) * stats.f_frsize;
            result.available = stats.f_bavail * stats.f_frsize;
        }
    }
    result.paths = try paths.toOwnedSlice(a);
    return result;
}
fn capability(operation: w.IntentKind, ok: bool, reason: []const u8, utility: ?[]const u8, mode: bd.BDFSResizeFlags) w.HostCapability {
    return .{ .operation = operation, .backend = .host, .support = if (ok) .available else .unavailable, .reason = reason, .required_utility = utility, .grow = mode & (bd.BD_FS_OFFLINE_GROW | bd.BD_FS_ONLINE_GROW) != 0, .shrink = mode & (bd.BD_FS_OFFLINE_SHRINK | bd.BD_FS_ONLINE_SHRINK) != 0 };
}
fn tableName(kind: bd.BDPartTableType) ?[]const u8 {
    return switch (kind) {
        bd.BD_PART_TABLE_GPT => "gpt",
        bd.BD_PART_TABLE_MSDOS => "mbr",
        else => null,
    };
}
fn wireGuid(a: std.mem.Allocator, text_: ?[]const u8) !?[]const u8 {
    const text_value = text_ orelse return null;
    const raw = @import("../../planning/identity.zig").parseGuid(text_value) catch return null;
    return try a.dupe(u8, &std.fmt.bytesToHex(raw, .lower));
}
fn partition(a: std.mem.Allocator, io: std.Io, disk_id: ?[32]u8, p: bd.BDPartSpec) !w.HostPartition {
    const path = try a.dupeSentinel(u8, std.mem.span(p.path), 0);
    const basename = std.fs.path.basename(path);
    const sys = try a.print("/sys/class/block/{s}", .{basename});
    const uuid = try wireGuid(a, stringView(p.uuid));
    const type_guid = try wireGuid(a, stringView(p.type_guid));
    const fs = (try probe(a, path, "TYPE")) orelse try property(a, io, sys, "ID_FS_TYPE");
    const label = (try probe(a, path, "LABEL")) orelse try property(a, io, sys, "ID_FS_LABEL");
    const mount = try mounts(a, io, path);
    const protected = mount.protected or (if (type_guid) |v| std.mem.eql(u8, v, &@import("../../planning/identity.zig").Gpt.ESP) else false);
    const mounted = mount.paths.len != 0;
    const kind = if (fs) |v| std.meta.stringToEnum(w.FilesystemKind, v) else null;
    const partition_number = readU64File(a, io, sys, "partition") catch |read_error| if (read_error == error.FileNotFound) null else return read_error;
    const slot = if (partition_number) |value| blk: {
        if (value == 0) return error.InvalidPartitionNumber;
        break :blk std.math.cast(u32, value - 1) orelse return error.InvalidPartitionNumber;
    } else null;
    var result: w.HostPartition = .{
        .id = if (disk_id) |id| (if (uuid) |u| try partitionId(a, id, u) else null) orelse path else path,
        .path = path,
        // The plan's name is a filesystem label. GPT names and device paths
        // must not become labels when a volume is subsequently formatted.
        .name = label orelse "",
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
    const caps = try a.alloc(w.HostCapability, 5);
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
test "sysfs partition discovery ignores ordinary attribute files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "uevent", .data = "DEVTYPE=disk\n" });
    const path = try temp.dir.realPathFileAlloc(io, ".", a);
    const partitions = try sysfsParts(a, io, path, null);
    try std.testing.expectEqual(@as(usize, 0), partitions.len);
}

fn sysfsParts(a: std.mem.Allocator, io: std.Io, sys: []const u8, id: ?[32]u8) ![]const w.HostPartition {
    var dir = std.Io.Dir.cwd().openDir(io, sys, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var iter = dir.iterate();
    var result: std.ArrayList(w.HostPartition) = .empty;
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const base = try std.fs.path.join(a, &.{ sys, entry.name });
        const partition_number = (readU64File(a, io, base, "partition") catch |read_error| switch (read_error) {
            error.FileNotFound => continue,
            else => return read_error,
        }) orelse continue;
        if (partition_number == 0) return error.InvalidPartitionNumber;
        var p: bd.BDPartSpec = std.mem.zeroes(bd.BDPartSpec);
        p.path = try a.printSentinel("/dev/{s}", .{entry.name}, 0);
        p.name = try a.dupeSentinel(u8, entry.name, 0);
        p.start = ((try readU64File(a, io, base, "start")) orelse return error.EmptySysfsValue) * SYSFS_SECTOR_BYTES;
        p.size = ((try readU64File(a, io, base, "size")) orelse return error.EmptySysfsValue) * SYSFS_SECTOR_BYTES;
        p.uuid = if (try property(a, io, base, "ID_PART_ENTRY_UUID")) |u| try a.dupeSentinel(u8, u, 0) else null;
        p.type_guid = if (try property(a, io, base, "ID_PART_ENTRY_TYPE")) |u| try a.dupeSentinel(u8, u, 0) else null;
        try result.append(a, try partition(a, io, id, p));
    }
    return result.toOwnedSlice(a);
}
fn disk(a: std.mem.Allocator, io: std.Io, name: []const u8) !?w.HostDisk {
    const sys = try a.print("/sys/class/block/{s}", .{name});
    if ((readU8File(a, io, sys, "partition") catch |read_error| if (read_error == error.FileNotFound) null else return read_error) != null) return null;
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, sys, a) catch return null;
    const size = ((try readU64File(a, io, sys, "size")) orelse return error.EmptySysfsValue) * SYSFS_SECTOR_BYTES;
    if (size == 0) return null;
    const id = try physicalId(a, io, resolved);
    const path = try a.printSentinel("/dev/{s}", .{name}, 0);
    const sector = (try readU64File(a, io, sys, "queue/logical_block_size")) orelse return error.EmptySysfsValue;
    if (sector == 0) return error.InvalidSectorSize;
    var result: w.HostDisk = .{
        .path = path,
        .identity = if (id) |bytes| try a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower)) else null,
        .model = (readU8File(a, io, sys, "device/model") catch |read_error| if (read_error == error.FileNotFound) null else return read_error) orelse try a.dupe(u8, name),
        .capacity = try a.print("{d}", .{size}),
        .sector_size = std.math.cast(u32, sector) orelse return error.InvalidSectorSize,
        .read_only = ((try readU64File(a, io, sys, "ro")) orelse return error.EmptySysfsValue) != 0,
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
        result.partitions = try sysfsParts(a, io, sys, id);
    } else {
        defer {
            var i: usize = 0;
            while (parts[i] != null) : (i += 1) bd.bd_part_spec_free(parts[i]);
            bd.g_free(@ptrCast(parts));
        }
        var list: std.ArrayList(w.HostPartition) = .empty;
        var i: usize = 0;
        while (parts[i] != null) : (i += 1) try list.append(a, try partition(a, io, id, parts[i].*));
        result.partitions = try list.toOwnedSlice(a);
    }
    return result;
}

pub fn query(a: std.mem.Allocator, io: std.Io) !w.InventorySnapshot {
    @import("blockdev.zig").init();
    var names: std.ArrayList([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, "/sys/class/block", .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| try names.append(a, try a.dupe(u8, entry.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    var disks: std.ArrayList(w.HostDisk) = .empty;
    for (names.items) |name| if (try disk(a, io, name)) |value| try disks.append(a, value);
    var result: w.InventorySnapshot = .{ .version = proto.API_VERSION, .platform = .linux, .snapshot_id = "", .disks = try disks.toOwnedSlice(a) };
    result.snapshot_id = try @import("../../planning/identity.zig").fingerprint(a, result);
    return result;
}

test "partition identity matches the protocol GPT byte order" {
    const a = std.testing.allocator;
    const id = try partitionId(a, @splat(0xab), "c12a7328-f81f-11d2-ba4b-00a0c93ec93b");
    defer a.free(id.?);
    const expected = try @import("../../planning/identity.zig").partition(a, "abababababababababababababababababababababababababababababababab", "28732ac11ff8d211ba4b00a0c93ec93b");
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
        const actual = try partition(a, io, null, spec);
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
