//! Join native GPT geometry to Storage Management partitions and volumes.
const std = @import("std");
const proto = @import("proto");
const w = proto.wire;
const n = @import("native.zig");
const wmi = @import("wmi.zig");
const policy = @import("policy.zig");
const basic_data = n.win32.zig.Guid.initString(@import("../../planning/identity.zig").Gpt.BASIC_DATA_GUID);

fn partition(a: std.mem.Allocator, connection: wmi.Connection, crypt: EncryptionInventory, disk: w.HostDisk, disk_number: u32, raw: n.win32.system.ioctl.PARTITION_INFORMATION_EX) !w.HostPartition {
    const gpt = raw.Anonymous.Gpt;
    const uuid = try n.guid(a, gpt.PartitionId);
    var state: policy.State = .{};
    state.protected = !std.mem.eql(u8, std.mem.asBytes(&gpt.PartitionType), std.mem.asBytes(&basic_data)) or gpt.Attributes.ATTRIBUTE_PLATFORM_REQUIRED != 0;
    var result: w.HostPartition = .{
        .id = try @import("../../planning/identity.zig").partition(a, disk.identity.?, uuid),
        .offset = try a.print("{d}", .{raw.StartingOffset.QuadPart}),
        .length = try a.print("{d}", .{raw.PartitionLength.QuadPart}),
        .name = "", // Populated only from the associated volume's filesystem label.
        .encryption = .unknown,
        .partition_uuid = uuid,
        .type_guid = try n.guid(a, gpt.PartitionType),
        .attributes = try a.print("{d}", .{@as(u64, @bitCast(gpt.Attributes))}),
        .slot = raw.PartitionNumber -| 1,
    };
    var parts = try connection.query(a, try a.print("SELECT * FROM MSFT_Partition WHERE DiskNumber = {d} AND PartitionNumber = {d}", .{ disk_number, raw.PartitionNumber }));
    defer parts.deinit();
    if (try parts.next()) |part| {
        defer part.deinit();
        const provider_guid = @import("../../planning/identity.zig").parseGuid((try part.text(a, "Guid")) orelse return error.MissingPartitionIdentity) catch return error.WindowsPartitionMappingChanged;
        if (!std.mem.eql(u8, &provider_guid, std.mem.asBytes(&gpt.PartitionId)) or
            try part.number("Size") != raw.PartitionLength.QuadPart) return error.WindowsPartitionMappingChanged;
        state.protected = state.protected or (part.boolean("IsBoot") catch true) or (part.boolean("IsSystem") catch true) or (part.boolean("IsShadowCopy") catch true);
        state.read_only = disk.read_only or (part.boolean("IsReadOnly") catch true);
        state.offline = part.boolean("IsOffline") catch true;
        result.mountpoints = try part.texts(a, "AccessPaths");
        const relpath = (try part.text(a, "__RELPATH")) orelse return error.WindowsObjectPathUnavailable;
        var volumes = try connection.query(a, try a.print("ASSOCIATORS OF {{{s}}} WHERE AssocClass = MSFT_PartitionToVolume", .{relpath}));
        defer volumes.deinit();
        if (try volumes.next()) |volume| {
            defer volume.deinit();
            result.path = try volume.text(a, "Path");
            result.name = (try volume.text(a, "FileSystemLabel")) orelse "";
            state.fs = policy.filesystem((try volume.text(a, "FileSystem")) orelse "");
            state.healthy = (volume.number("HealthStatus") catch 2) == 0;
            if (result.path) |path| {
                state.encrypted = crypt.lookup(path);
                state.simple = n.simpleVolume(a, path, disk_number, @intCast(raw.StartingOffset.QuadPart), @intCast(raw.PartitionLength.QuadPart));
            }
            const size = volume.number("Size") catch 0;
            const free = volume.number("SizeRemaining") catch 0;
            if (free <= size and size != 0) {
                result.used_bytes = try a.print("{d}", .{size - free});
                result.free_bytes = try a.print("{d}", .{free});
            }
            if (try volumes.next()) |extra| {
                extra.deinit();
                state.simple = false;
            }
        }
        if (try parts.next()) |extra| {
            extra.deinit();
            state.simple = false;
        }
    }
    result.filesystem = state.fs;
    result.encryption = state.encrypted;
    result.protected = state.protected;
    result.capabilities = try policy.capabilities(a, state);
    return result;
}
pub fn query(a: std.mem.Allocator, _: std.Io) !w.InventorySnapshot {
    var failure: wmi.Failure = .{};
    const apartment = try wmi.Apartment.init(&failure);
    defer apartment.deinit();
    const connection = try wmi.Connection.init(a, wmi.STORAGE_NAMESPACE, &failure);
    defer connection.deinit();
    const crypt = try EncryptionInventory.query(a);
    var objects = try connection.query(a, "SELECT * FROM MSFT_Disk");
    defer objects.deinit();
    var disks: std.ArrayList(w.HostDisk) = .empty;
    while (try objects.next()) |object| {
        defer object.deinit();
        const number = std.math.cast(u32, try object.number("Number")) orelse return error.InvalidWindowsNumber;
        var disk: w.HostDisk = .{
            .path = (try object.text(a, "Path")) orelse return error.WindowsDevicePathUnavailable,
            .capacity = try a.print("{d}", .{try object.number("Size")}),
            .sector_size = std.math.cast(u32, try object.number("LogicalSectorSize")) orelse return error.InvalidWindowsNumber,
            .physical_block_size = std.math.cast(u32, try object.number("PhysicalSectorSize")),
            .model = (try object.text(a, "FriendlyName")) orelse "Windows disk",
            .read_only = (object.boolean("IsReadOnly") catch true) or (object.boolean("IsOffline") catch true) or (object.boolean("IsClustered") catch true) or (object.number("BusType") catch 16) == 16,
            .partition_table = switch (try object.number("PartitionStyle")) {
                1 => "mbr",
                2 => "gpt",
                else => "raw",
            },
        };
        const handle = n.open(a, disk.path, n.GENERIC_READ) catch {
            disk.read_only = true;
            disk.diagnostics = &.{.{ .code = "windows_layout_access_required", .severity = .warning, .message = "Administrator access is required to read the full disk layout." }};
            try disks.append(a, disk);
            continue;
        };
        defer n.close(handle);
        if (try n.deviceNumber(handle) != number) return error.WindowsDiskMappingChanged;
        const layout = n.readLayout(a, handle) catch {
            disk.read_only = true;
            disk.diagnostics = &.{.{ .code = "windows_layout_unavailable", .severity = .warning, .message = "Native disk layout could not be verified." }};
            try disks.append(a, disk);
            continue;
        };
        defer layout.deinit(a);
        if (layout.header.PartitionStyle == 1) {
            const gpt = layout.header.Anonymous.Gpt;
            if (gpt.StartingUsableOffset.QuadPart < 0 or gpt.UsableLength.QuadPart <= 0) return error.InvalidWindowsDiskLayout;
            // Prefer the same device-associated VPD identity as Linux maintenance.
            // Older providers retain a host-only identity rather than inventing a
            // supposedly portable mapping from their UniqueId/SerialNumber text.
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update("pizza-windows-gpt-identity-v2");
            // Provider hardware IDs supplement GPT identity; they are never query text.
            hash.update((try object.text(a, "UniqueId")) orelse "");
            hash.update(&.{0});
            hash.update((try object.text(a, "SerialNumber")) orelse "");
            hash.update(std.mem.asBytes(&gpt.DiskId));
            hash.update(std.mem.asBytes(&disk.sector_size));
            const capacity = try proto.byteCount(disk.capacity);
            hash.update(std.mem.asBytes(&capacity));
            const portable = n.maintenanceIdentity(a, handle) catch null;
            const disk_id = portable orelse hash.finalResult();
            disk.identity = try a.dupe(u8, &std.fmt.bytesToHex(disk_id, .lower));
            if (portable == null) disk.diagnostics = &.{.{ .code = "maintenance_identity_unavailable", .severity = .warning, .message = "The storage driver exposes no unambiguous portable NAA/EUI identifier; only Windows host operations are available." }};
            disk.usable_offset = try a.print("{d}", .{gpt.StartingUsableOffset.QuadPart});
            disk.usable_length = try a.print("{d}", .{gpt.UsableLength.QuadPart});
            var parts: std.ArrayList(w.HostPartition) = .empty;
            for (layout.entries) |p| {
                if (p.PartitionStyle != .GPT or p.PartitionLength.QuadPart == 0) continue;
                if (p.StartingOffset.QuadPart < 0 or p.PartitionLength.QuadPart < 0 or p.PartitionNumber == 0) return error.InvalidWindowsDiskLayout;
                try parts.append(a, try partition(a, connection, crypt, disk, number, p));
            }
            disk.partitions = try parts.toOwnedSlice(a);
        } else disk.read_only = true;
        try disks.append(a, disk);
    }
    // Cloned images may carry identical GPT and provider IDs. Refuse ambiguous writes.
    for (disks.items) |*disk| {
        const id = disk.identity orelse continue;
        var matches: usize = 0;
        for (disks.items) |other| if (other.identity) |other_id| {
            if (std.mem.eql(u8, id, other_id)) {
                matches += 1;
            }
        };
        if (matches < 2) continue;
        disk.read_only = true;
        disk.diagnostics = &.{.{ .code = "ambiguous_windows_disk_identity", .severity = .warning, .message = "Multiple disks report the same identity; writes are disabled." }};
    }
    var result: w.InventorySnapshot = .{ .version = proto.API_VERSION, .snapshot_id = "", .platform = .windows, .disks = try disks.toOwnedSlice(a), .diagnostics = if (crypt.complete) &.{} else &.{.{ .code = "windows_encryption_detection_unavailable", .severity = .warning, .message = "Encryption detection is unavailable; affected volumes remain non-writable." }} };
    result.snapshot_id = try @import("../../planning/identity.zig").fingerprint(a, result);
    return result;
}

// Detection only; encrypted or unverified volumes stay non-writable.
const EncryptionInventory = struct {
    const Entry = struct { path: []const u8, state: policy.Encryption };
    entries: []const Entry = &.{},
    complete: bool = false,
    fn lookup(self: EncryptionInventory, path: []const u8) policy.Encryption {
        for (self.entries) |e| if (std.ascii.eqlIgnoreCase(e.path, path)) return e.state;
        return if (self.complete) .none else .unknown;
    }
    fn query(a: std.mem.Allocator) !EncryptionInventory {
        var failure: wmi.Failure = .{};
        const connection = wmi.Connection.init(a, wmi.BITLOCKER_NAMESPACE, &failure) catch return .{};
        defer connection.deinit();
        var objects = connection.query(a, "SELECT * FROM Win32_EncryptableVolume") catch return .{};
        defer objects.deinit();
        var entries: std.ArrayList(Entry) = .empty;
        while (objects.next() catch return .{}) |object| {
            defer object.deinit();
            const path = (object.text(a, "DeviceID") catch return .{}) orelse return .{};
            const result = connection.method(a, object, "GetConversionStatus", &.{.{ .name = @import("native.zig").wideLiteral("PrecisionFactor"), .value = .{ .uint32 = 0 } }}) catch {
                try entries.append(a, .{ .path = path, .state = .unknown });
                continue;
            };
            defer result.deinit();
            try entries.append(a, .{ .path = path, .state = policy.encryption(result.number("ConversionStatus") catch null) });
        }
        return .{ .entries = try entries.toOwnedSlice(a), .complete = true };
    }
};
