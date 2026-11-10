//! Destructive acceptance exclusively on a private, handle-owned temporary VHDX.
//! Run explicitly with test-windows-image in an elevated Windows process.
const std = @import("std");
const proto = @import("proto");
const wire = proto.wire;
const native_api = @import("../core/platform/windows/native.zig");
const wmi = @import("../core/platform/windows/wmi.zig");
const Disk = @import("../core/platform/windows/disk.zig");
const state = @import("../core/execution/state.zig");
const vhd = native_api.win32.storage.vhd;
const vd = native_api.win32.virtdisk;

const MIB = 1024 * 1024;
const SENTINEL_BYTES = 2 * MIB;
const SENTINEL_CHUNK_BYTES = 64 * 1024;
const FIXTURE_TIMEOUT_MS = 30_000;
const EXECUTION_TIMEOUT_MS = 120_000;

const Geometry = struct {
    capacity: u64,
    sector_bytes: u32,
    physical_sector_bytes: u32,
    pub fn dataOffset(self: Geometry) u64 {
        return self.capacity / 32;
    }
    pub fn dataLength(self: Geometry) u64 {
        return self.capacity / 2;
    }
    pub fn guardOffset(self: Geometry) u64 {
        return self.capacity / 4 * 3;
    }
    pub fn guardLength(self: Geometry) u64 {
        return self.capacity / 8;
    }
};

fn check(code: native_api.foundation.WIN32_ERROR) !void {
    if (code != .NO_ERROR) {
        std.debug.print("VHDX fixture: Win32 error {d}\n", .{@backingInt(code)});
        return error.VirtualDiskFixtureFailed;
    }
}
const Privilege = struct {
    token: native_api.foundation.HANDLE,
    previous: native_api.win32.security.TOKEN_PRIVILEGES,
    fn enable() !Privilege {
        if (!@import("../core/platform/windows/session/security.zig").elevated()) return error.ElevatedWindowsRequired;
        const adv = native_api.win32.advapi32;
        var token: ?native_api.foundation.HANDLE = null;
        if (adv.OpenProcessToken(native_api.kernel32.GetCurrentProcess(), .{ .QUERY = 1, .ADJUST_PRIVILEGES = 1 }, &token) == 0) return error.VolumePrivilegeUnavailable;
        const handle = token orelse return error.VolumePrivilegeUnavailable;
        errdefer _ = native_api.kernel32.CloseHandle(handle);
        var requested = std.mem.zeroes(native_api.win32.security.TOKEN_PRIVILEGES);
        requested.PrivilegeCount = 1;
        requested.Privileges[0].Attributes = .{ .ENABLED = 1 };
        if (adv.LookupPrivilegeValueW(null, native_api.wideLiteral("SeManageVolumePrivilege"), &requested.Privileges[0].Luid) == 0) return error.VolumePrivilegeUnavailable;
        var previous = std.mem.zeroes(native_api.win32.security.TOKEN_PRIVILEGES);
        var size: u32 = 0;
        if (adv.AdjustTokenPrivileges(handle, 0, &requested, @sizeOf(@TypeOf(previous)), &previous, &size) == 0 or native_api.kernel32.GetLastError() != .NO_ERROR) return error.VolumePrivilegeUnavailable;
        return .{ .token = handle, .previous = previous };
    }
    fn deinit(self: *Privilege) void {
        _ = native_api.win32.advapi32.AdjustTokenPrivileges(self.token, 0, &self.previous, 0, null, null);
        _ = native_api.kernel32.CloseHandle(self.token);
    }
};
const Fixture = struct {
    temp: std.testing.TmpDir,
    handle: ?native_api.foundation.HANDLE,
    number: u32,
    geometry: Geometry,
    fn create(a: std.mem.Allocator, geometry: Geometry) !Fixture {
        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();
        var path_buffer: [32768]u8 = undefined;
        const length = try temp.dir.realPath(std.testing.io, &path_buffer);
        const path = try native_api.wide(a, try a.print("{s}\\fixture.vhdx", .{path_buffer[0..length]}));
        var kind: vhd.VIRTUAL_STORAGE_TYPE = .{ .DeviceId = vhd.VIRTUAL_STORAGE_TYPE_DEVICE_VHDX, .VendorId = vhd.VIRTUAL_STORAGE_TYPE_VENDOR_MICROSOFT };
        var parameters = std.mem.zeroes(vhd.CREATE_VIRTUAL_DISK_PARAMETERS);
        parameters.Version = .@"2";
        parameters.Anonymous.Version2.MaximumSize = geometry.capacity;
        parameters.Anonymous.Version2.SectorSizeInBytes = geometry.sector_bytes;
        parameters.Anonymous.Version2.PhysicalSectorSizeInBytes = geometry.physical_sector_bytes;
        var handle: ?native_api.foundation.HANDLE = null;
        try check(vd.CreateVirtualDisk(&kind, path, .{}, null, .{}, 0, &parameters, null, &handle));
        const opened = handle orelse return error.InvalidVirtualDiskHandle;
        errdefer _ = native_api.kernel32.CloseHandle(opened);
        var attach = std.mem.zeroes(vhd.ATTACH_VIRTUAL_DISK_PARAMETERS);
        attach.Version = .@"1";
        // Keep attachment tied to this handle, including when the test crashes.
        try check(vd.AttachVirtualDisk(opened, null, .{ .NO_DRIVE_LETTER = 1 }, 0, &attach, null));
        errdefer _ = vd.DetachVirtualDisk(opened, .{}, 0);
        const number = try diskNumber(a, opened);
        return .{ .temp = temp, .handle = opened, .number = number, .geometry = geometry };
    }
    fn diskNumber(a: std.mem.Allocator, handle: native_api.foundation.HANDLE) !u32 {
        var path: [512:0]u16 = @splat(0);
        var bytes: u32 = @sizeOf(@TypeOf(path));
        try check(vd.GetVirtualDiskPhysicalPath(handle, &bytes, &path));
        const device = try std.unicode.utf16LeToUtf8Alloc(a, std.mem.sliceTo(&path, 0));
        const disk = try native_api.open(a, device, 0);
        defer _ = native_api.kernel32.CloseHandle(disk);
        return native_api.deviceNumber(disk);
    }
    fn assertOwned(self: *const Fixture, a: std.mem.Allocator, disk: wire.HostDisk) !void {
        if (try diskNumber(a, self.handle orelse return error.DetachedFixture) != self.number) return error.FixtureMappingChanged;
        const handle = try native_api.open(a, disk.path, 0);
        defer _ = native_api.kernel32.CloseHandle(handle);
        if (try native_api.deviceNumber(handle) != self.number or try proto.byteCount(disk.capacity) != self.geometry.capacity) return error.ForeignDiskRejected;
    }
    fn object(self: *const Fixture, a: std.mem.Allocator, connection: wmi.Connection) !wmi.Object {
        if (try diskNumber(a, self.handle orelse return error.DetachedFixture) != self.number) return error.FixtureMappingChanged;
        // PnP can publish the disk before the storage provider enumerates it.
        const until = native_api.kernel32.GetTickCount64() + FIXTURE_TIMEOUT_MS;
        while (native_api.kernel32.GetTickCount64() < until) {
            var disks = try connection.query(a, try a.print("SELECT * FROM MSFT_Disk WHERE Number = {d}", .{self.number}));
            defer disks.deinit();
            const disk = (try disks.next()) orelse {
                native_api.kernel32.Sleep(100);
                continue;
            };
            errdefer disk.deinit();
            // Bootstrap must never initialize an already populated or physical disk.
            if (try disk.number("Size") != self.geometry.capacity or try disk.number("BusType") != 15 or
                try disk.boolean("IsSystem") or try disk.boolean("IsBoot")) return error.ForeignDiskRejected;
            const path = (try disk.text(a, "Path")) orelse return error.MissingFixturePath;
            const native = try native_api.open(a, path, 0);
            defer _ = native_api.kernel32.CloseHandle(native);
            if (try native_api.deviceNumber(native) != self.number) return error.FixtureMappingChanged;
            if (try disks.next()) |extra| {
                extra.deinit();
                return error.AmbiguousFixture;
            }
            return disk;
        }
        return error.FixtureNotEnumerated;
    }
    fn bootstrap(self: *const Fixture, a: std.mem.Allocator, connection: wmi.Connection, initial_label: []const u8) !void {
        const disk = try self.object(a, connection);
        defer disk.deinit();
        if (try disk.number("PartitionStyle") != 0 or try disk.number("NumberOfPartitions") != 0) return error.NonemptyFixtureRejected;
        if (try disk.boolean("IsOffline")) {
            const online = try connection.method(a, disk, "Online", &.{});
            online.deinit();
        }
        const initialized = try connection.method(a, disk, "Initialize", &.{.{ .name = native_api.wideLiteral("PartitionStyle"), .value = .{ .uint32 = 2 } }});
        initialized.deinit();
        for ([_][2]u64{ .{ self.geometry.dataOffset(), self.geometry.dataLength() }, .{ self.geometry.guardOffset(), self.geometry.guardLength() } }) |geometry| {
            const current = try self.object(a, connection);
            defer current.deinit();
            const result = try connection.method(a, current, "CreatePartition", &.{
                .{ .name = native_api.wideLiteral("Size"), .value = .{ .uint64 = geometry[1] } },
                .{ .name = native_api.wideLiteral("Offset"), .value = .{ .uint64 = geometry[0] } },
                .{ .name = native_api.wideLiteral("GptType"), .value = .{ .text = "{" ++ @import("../core/planning/identity.zig").Gpt.BASIC_DATA_GUID ++ "}" } },
                .{ .name = native_api.wideLiteral("AssignDriveLetter"), .value = .{ .boolean = false } },
            });
            result.deinit();
            const volume = try self.waitVolume(a, connection, geometry[0]);
            defer volume.deinit();
            const formatted = try connection.method(a, volume, "Format", &.{
                .{ .name = native_api.wideLiteral("FileSystem"), .value = .{ .text = "NTFS" } },
                .{ .name = native_api.wideLiteral("FileSystemLabel"), .value = .{ .text = initial_label } },
                .{ .name = native_api.wideLiteral("Full"), .value = .{ .boolean = false } },
                .{ .name = native_api.wideLiteral("Force"), .value = .{ .boolean = false } },
            });
            formatted.deinit();
        }
    }
    fn waitVolume(self: *const Fixture, a: std.mem.Allocator, connection: wmi.Connection, offset: u64) !wmi.Object {
        const until = native_api.kernel32.GetTickCount64() + FIXTURE_TIMEOUT_MS;
        while (native_api.kernel32.GetTickCount64() < until) {
            var parts = try connection.query(a, try a.print("SELECT * FROM MSFT_Partition WHERE DiskNumber = {d} AND Offset = {d}", .{ self.number, offset }));
            defer parts.deinit();
            if (try parts.next()) |part| {
                defer part.deinit();
                const relpath = (try part.text(a, "__RELPATH")) orelse return error.MissingFixturePath;
                var volumes = try connection.query(a, try a.print("ASSOCIATORS OF {{{s}}} WHERE AssocClass = MSFT_PartitionToVolume", .{relpath}));
                defer volumes.deinit();
                if (try volumes.next()) |volume| return volume;
            }
            native_api.kernel32.Sleep(100);
        }
        return error.FixtureVolumeTimeout;
    }
    fn snapshot(self: *const Fixture, a: std.mem.Allocator, backend: *Disk) !wire.HostDisk {
        const snapshot_value = try backend.query(a);
        for (snapshot_value.disks) |disk| {
            const handle = native_api.open(a, disk.path, 0) catch continue;
            defer _ = native_api.kernel32.CloseHandle(handle);
            if (try native_api.deviceNumber(handle) != self.number) continue;
            try self.assertOwned(a, disk);
            return disk;
        }
        return error.FixtureNotEnumerated;
    }
    fn detach(self: *Fixture) !void {
        const handle = self.handle orelse return;
        try check(vd.DetachVirtualDisk(handle, .{}, 0));
        _ = native_api.kernel32.CloseHandle(handle);
        self.handle = null;
    }
    fn deinit(self: *Fixture) void {
        if (self.handle) |handle| {
            _ = vd.DetachVirtualDisk(handle, .{}, 0);
            _ = native_api.kernel32.CloseHandle(handle);
        }
        self.temp.cleanup();
    }
};
fn partAt(disk: wire.HostDisk, offset: u64) !wire.HostPartition {
    for (disk.partitions) |part| if (try proto.byteCount(part.offset) == offset) return part;
    return error.MissingFixturePartition;
}
fn desired(part: wire.HostPartition) wire.DesiredPartition {
    return .{ .id = part.id, .offset = part.offset, .length = part.length, .name = part.name, .filesystem = part.filesystem, .partition_uuid = part.partition_uuid, .type_guid = part.type_guid };
}
fn sentinelPath(a: std.mem.Allocator, part: wire.HostPartition) ![]const u8 {
    return a.print("{s}pizza-sentinel.bin", .{part.path orelse return error.MissingFixtureVolume});
}
fn writeSentinel(a: std.mem.Allocator, part: wire.HostPartition) ![32]u8 {
    const path = try sentinelPath(a, part);
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .exclusive = true });
    defer file.close(std.testing.io);
    var bytes: [SENTINEL_CHUNK_BYTES]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (0..SENTINEL_BYTES / SENTINEL_CHUNK_BYTES) |block| {
        for (&bytes, 0..) |*byte, index| byte.* = @truncate(index * 37 + block * 13);
        hash.update(&bytes);
        try file.writePositionalAll(std.testing.io, &bytes, block * bytes.len);
    }
    try file.sync(std.testing.io);
    return hash.finalResult();
}
fn verifySentinel(a: std.mem.Allocator, part: wire.HostPartition, expected: [32]u8) !void {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, try sentinelPath(a, part), .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u64, SENTINEL_BYTES), stat.size);
    var bytes: [SENTINEL_CHUNK_BYTES]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (0..SENTINEL_BYTES / SENTINEL_CHUNK_BYTES) |block| {
        try std.testing.expectEqual(bytes.len, try file.readPositionalAll(std.testing.io, &bytes, block * bytes.len));
        hash.update(&bytes);
    }
    try std.testing.expectEqual(expected, hash.finalResult());
}
// The acceptance test uses the same service, plan generator, approval routing
// and worker as both clients. The adapter adds ownership checks on every write.
const OwnedDisk = struct {
    fixture: *const Fixture,
    backend: *Disk,
    pub fn query(self: *@This(), a: std.mem.Allocator) !wire.InventorySnapshot {
        return self.backend.query(a);
    }
    pub fn validLabel(self: *@This(), a: std.mem.Allocator, fs: wire.FilesystemKind, label: []const u8) !bool {
        return self.backend.validLabel(a, fs, label);
    }
    pub fn canFs(self: *@This(), a: std.mem.Allocator, fs: wire.FilesystemKind, op: wire.IntentKind, mounted: bool, shrinking: bool) !bool {
        return self.backend.canFs(a, fs, op, mounted, shrinking);
    }
    pub fn preflightShrink(self: *@This(), a: std.mem.Allocator, p: wire.HostPartition, length: u64) !void {
        return self.backend.preflightShrink(a, p, length);
    }
    pub fn apply(self: *@This(), a: std.mem.Allocator, disk: wire.HostDisk, op: wire.PlanIntent, p: ?wire.DesiredPartition) !void {
        try self.fixture.assertOwned(a, disk);
        return self.backend.apply(a, disk, op, p);
    }
    pub fn failureMessage(self: *@This(), err: anyerror) []const u8 {
        return self.backend.failureMessage(err);
    }
};
const TestSessions = struct {
    worker: @import("../core/execution/worker.zig") = .{},
    store: struct {
        record: ?[]const u8 = null,
        pub fn persist(self: *@This(), _: []const u8, bytes: []const u8) !void {
            const next = try std.heap.page_allocator.dupe(u8, bytes);
            if (self.record) |old| std.heap.page_allocator.free(old);
            self.record = next;
        }
        pub fn read(self: *@This(), a: std.mem.Allocator, _: []const u8) !?[]const u8 {
            return if (self.record) |bytes| try a.dupe(u8, bytes) else null;
        }
        pub fn latest(_: *@This(), _: std.mem.Allocator) !?[]const u8 {
            return null;
        }
    } = .{},
    pub fn isPrivileged(_: *@This()) bool {
        return true;
    }
    pub fn call(_: *@This(), _: std.mem.Allocator, _: []const u8) !?[]const u8 {
        return error.UnexpectedAuthorization;
    }
    pub fn elevate(_: *@This(), _: std.mem.Allocator, _: []const u8) !?[]const u8 {
        return error.UnexpectedAuthorization;
    }
};
fn apply(fixture: *const Fixture, a: std.mem.Allocator, backend: *Disk, before: wire.HostDisk, kind: wire.IntentKind, target: wire.DesiredPartition) !wire.HostDisk {
    try fixture.assertOwned(a, before);
    const application = @import("../core/app/service.zig");
    const editor = @import("../core/planning/editor.zig");
    var service: application.service(OwnedDisk, TestSessions) = .{ .io = std.testing.io, .disk = .{ .fixture = fixture, .backend = backend } };
    defer {
        service.sessions.worker.wait(service.io);
        if (service.sessions.store.record) |record| std.heap.page_allocator.free(record);
    }
    const snapshot = try service.disk.query(a);
    const disk = try fixture.snapshot(a, backend);
    var layout: std.ArrayList(wire.DesiredPartition) = .empty;
    for (disk.partitions) |p| try layout.append(a, if (std.mem.eql(u8, p.id, target.id)) target else editor.retained(p));
    const response = try service.plan(a, try std.json.Stringify.valueAlloc(a, editor.Request{ .version = proto.API_VERSION, .snapshot_id = snapshot.snapshot_id, .disk_identity = disk.identity.?, .layout = layout.items, .review = true }, .{ .emit_null_optional_fields = false }));
    const plan = (try std.json.parseFromSliceLeaky(editor.Result, a, response, .{})).validated.?;
    if (!plan.executable) {
        std.debug.print("VHDX plan diagnostics: {any}\n", .{plan.diagnostics});
        return error.PlanNotExecutable;
    }
    const start = try service.dispatch(a, try std.json.Stringify.valueAlloc(a, wire.PrivilegedRequest{ .version = proto.API_VERSION, .action = .execute, .draft = plan.draft, .approved_digest = plan.digest }, .{ .emit_null_optional_fields = false }), .privileged);
    const queued = try std.json.parseFromSliceLeaky(wire.ExecutionSession, a, start, .{});
    const until = native_api.kernel32.GetTickCount64() + EXECUTION_TIMEOUT_MS;
    while (service.sessions.worker.busy()) {
        if (native_api.kernel32.GetTickCount64() > until) {
            _ = service.sessions.worker.cancelExecution(queued.id);
            return error.ExecutionTimedOut;
        }
        native_api.kernel32.Sleep(10);
    }
    const status = try service.dispatch(a, try std.json.Stringify.valueAlloc(a, wire.PrivilegedRequest{ .version = proto.API_VERSION, .action = .status, .session_id = queued.id, .approved_digest = plan.digest }, .{ .emit_null_optional_fields = false }), .privileged);
    const completed = try std.json.parseFromSliceLeaky(wire.ExecutionSession, a, status, .{});
    if (completed.status != .succeeded) {
        std.debug.print("VHDX execution: {s}\n", .{status});
        return error.AcceptanceExecutionFailed;
    }
    const after = try fixture.snapshot(a, backend);
    try state.verify(before, after, .{ .kind = kind, .partition_id = target.id }, target);
    return after;
}
test "Windows backend plans and executes on private VHDX across geometries and sector sizes" {
    for ([_]Geometry{
        .{ .capacity = 1024 * MIB, .sector_bytes = 512, .physical_sector_bytes = 4096 },
        .{ .capacity = 1536 * MIB, .sector_bytes = 4096, .physical_sector_bytes = 4096 },
    }) |geometry| try acceptance(geometry);
}
fn acceptance(geometry: Geometry) !void {
    var privilege = try Privilege.enable();
    defer privilege.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try Fixture.create(a, geometry);
    defer fixture.deinit();
    const apartment = try wmi.ComScope.init();
    defer apartment.deinit();
    const connection = try wmi.Connection.init(a, wmi.STORAGE_NAMESPACE);
    defer connection.deinit();
    var random: [8]u8 = undefined;
    std.testing.io.random(&random);
    const initial_label = std.fmt.bytesToHex(random[0..4].*, .lower);
    var codepoint: [4]u8 = undefined;
    const unicode_length = try std.unicode.utf8Encode(@as(u21, 0x4e00) + random[0], &codepoint);
    const requested_label = try a.print("{s}-{s}", .{ codepoint[0..unicode_length], &initial_label });
    try fixture.bootstrap(a, connection, &initial_label);
    var backend: Disk = .{ .io = std.testing.io };
    var disk = try fixture.snapshot(a, &backend);
    var part = try partAt(disk, geometry.dataOffset());
    // Do not bypass encryption detection or manufacture production capabilities.
    for ([_]wire.IntentKind{ .resize, .label, .format }) |kind| {
        const ready = for (part.capabilities) |cap| {
            if (cap.operation == kind and cap.support == .available) break true;
        } else false;
        if (!ready) {
            std.debug.print("{s} unavailable: encryption={t}, protected={any}, capabilities={any}\n", .{ @tagName(kind), part.encryption, part.protected, part.capabilities });
            return error.FixtureWriteCapabilityUnavailable;
        }
    }
    const data_hash = try writeSentinel(a, part);
    const guard_hash = try writeSentinel(a, try partAt(disk, geometry.guardOffset()));
    try std.testing.expectError(error.HostPreflightFailed, backend.preflightShrink(a, part, geometry.sector_bytes));
    var target = desired(part);
    target.name = try a.print("{s}/{s}", .{ initial_label, initial_label });
    try std.testing.expectError(error.InvalidFilesystemLabel, backend.apply(a, disk, .{ .kind = .label, .partition_id = part.id }, target));
    try std.testing.expectError(error.WindowsOperationUnsupported, backend.apply(a, disk, .{ .kind = .copy, .partition_id = part.id }, target));
    var stale = disk;
    stale.capacity = "1";
    try std.testing.expectError(error.LayoutChanged, backend.apply(a, stale, .{ .kind = .label, .partition_id = part.id }, desired(part)));
    try state.unchanged(disk, try fixture.snapshot(a, &backend));
    try verifySentinel(a, part, data_hash);
    try verifySentinel(a, try partAt(disk, geometry.guardOffset()), guard_hash);
    target = desired(part);
    target.name = requested_label;
    disk = try apply(&fixture, a, &backend, disk, .label, target);
    part = try partAt(disk, geometry.dataOffset());
    try verifySentinel(a, part, data_hash);
    try verifySentinel(a, try partAt(disk, geometry.guardOffset()), guard_hash);
    for ([_]u64{ geometry.dataLength() / 4 * 3, geometry.dataLength() / 4 * 5 }) |size| {
        try backend.preflightShrink(a, part, size);
        target = desired(part);
        target.length = try a.print("{d}", .{size});
        disk = try apply(&fixture, a, &backend, disk, .resize, target);
        part = try partAt(disk, geometry.dataOffset());
        try verifySentinel(a, part, data_hash);
        try verifySentinel(a, try partAt(disk, geometry.guardOffset()), guard_hash);
    }
    for ([_]wire.FilesystemKind{ .exfat, .vfat, .ntfs }) |fs| {
        target = desired(part);
        target.filesystem = fs;
        var label_bytes: [5]u8 = undefined;
        std.testing.io.random(&label_bytes);
        target.name = try std.ascii.allocUpperString(a, &std.fmt.bytesToHex(label_bytes, .lower));
        target.retain_data = false;
        disk = try apply(&fixture, a, &backend, disk, .format, target);
        part = try partAt(disk, geometry.dataOffset());
        if (std.Io.Dir.cwd().openFile(std.testing.io, try sentinelPath(a, part), .{})) |file| {
            file.close(std.testing.io);
            return error.FormattedSentinelSurvived;
        } else |err| if (err != error.FileNotFound) return err;
        const hash = try writeSentinel(a, part);
        try verifySentinel(a, part, hash);
        try verifySentinel(a, try partAt(disk, geometry.guardOffset()), guard_hash);
    }
    try fixture.detach();
}
