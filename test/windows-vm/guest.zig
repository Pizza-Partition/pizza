//! Elevated acceptance driver. All Windows operations use the locked zigwin32
//! bindings and the production WMI adapter. CMD only launches this executable.
const std = @import("std");
const u = @import("vm_common");
const proto = @import("proto");
const w = proto.wire;
const n = @import("core/platform/windows/native.zig");
const wmi = @import("core/platform/windows/wmi.zig");
const editor = @import("core/planning/editor.zig");
const cli = @import("cli.zig");
const shared = @import("shared_guest.zig");
const Guest = shared.Guest(Platform);
const layouts = shared.layouts;
const MIB = 1024 * 1024;
const Owned = struct { serial: []const u8, wwn: []const u8, number: u32, guid: []const u8, data_uuid: []const u8 };
const Platform = struct {
    pub const extension = ".exe";
    pub const test_dir = "windows-tests";
    failure: wmi.Failure = .{},
    pub fn owned(g: *Guest, c: wmi.Connection) !wmi.Object {
        var disks = try c.query(g.a, "SELECT * FROM MSFT_Disk");
        defer disks.deinit();
        var selected: ?wmi.Object = null;
        errdefer if (selected) |d| d.deinit();
        while (try disks.next()) |d| {
            const s = (try d.text(g.a, "SerialNumber")) orelse "";
            if (!std.mem.eql(u8, std.mem.trim(u8, s, " \t\r\n"), g.serial)) {
                d.deinit();
                continue;
            }
            errdefer d.deinit();
            if (selected != null) return error.AmbiguousOwnedDisk;
            const bus = try d.number("BusType");
            if (try d.boolean("IsBoot") or try d.boolean("IsSystem") or try d.number("Size") != 4 * 1024 * MIB or (bus != 1 and bus != 10)) return error.ForeignDiskRejected;
            if (!std.ascii.eqlIgnoreCase((try d.text(g.a, "UniqueId")) orelse "", g.wwn)) return error.ForeignWwnRejected;
            const handle = try n.open(g.a, (try d.text(g.a, "Path")) orelse return error.MissingDiskPath, 0);
            defer n.close(handle);
            if (try n.deviceNumber(handle) != try d.number("Number")) return error.DiskMappingChanged;
            const layout = try n.readLayout(g.a, handle);
            defer layout.deinit(g.a);
            selected = d;
        }
        return selected orelse error.OwnedDiskMissing;
    }
    pub fn awaitInventory(g: Guest) !void {
        const until = n.k.GetTickCount64() + 60000;
        var nonce: [6]u8 = undefined;
        g.io.random(&nonce);
        var attempt: usize = 0;
        var consecutive: usize = 0;
        while (n.k.GetTickCount64() < until) : (attempt += 1) {
            // The serial SCM service can start before the Storage WMI provider.
            // Only this read-only inventory is polled. Never replay a request
            // that prepares, executes, imports or changes a disk.
            const result = try u.runAt(g.a, g.io, null, .inherit, &.{ try g.path("pizza-backend.exe"), "inventory" }, null, 60);
            const prefix = try g.a.print("readiness-{s}-{d}", .{ std.fmt.bytesToHex(nonce, .lower), attempt });
            try std.Io.Dir.cwd().writeFile(g.io, .{ .sub_path = try g.path(try g.a.print("{s}.stdout", .{prefix})), .data = result.stdout });
            try std.Io.Dir.cwd().writeFile(g.io, .{ .sub_path = try g.path(try g.a.print("{s}.stderr", .{prefix})), .data = result.stderr });
            if (result.term.success()) {
                const value = try std.json.parseFromSliceLeaky(w.InventorySnapshot, g.a, result.stdout, .{});
                if (value.disks.len == 0) return error.EmptyInventory;
                consecutive += 1;
                if (consecutive == 2) return;
            } else {
                if (std.mem.indexOf(u8, result.stderr, "error: WindowsWmiFailed") == null) {
                    _ = try u.check(result);
                    unreachable;
                }
                consecutive = 0;
            }
            n.k.Sleep(1000);
        }
        return error.StorageReadinessTimeout;
    }
    pub fn target(g: Guest, s: w.InventorySnapshot) !w.HostDisk {
        const owner = try g.load(Owned, "owned-disk.json");
        for (s.disks) |d| {
            if (try proto.byteCount(d.capacity) != 4 * 1024 * MIB) continue;
            for (d.partitions) |p| if (p.partition_uuid != null and std.mem.eql(u8, p.partition_uuid.?, owner.data_uuid)) {
                const h = try n.open(g.a, d.path, 0);
                defer n.close(h);
                if (try n.deviceNumber(h) != owner.number) return error.TargetMappingChanged;
                return d;
            };
        }
        return error.TargetMissing;
    }
    pub fn fileHash(g: Guest, d: w.HostDisk) ![]const u8 {
        const owner = try g.load(Owned, "owned-disk.json");
        const h = try n.open(g.a, d.path, 0);
        defer n.close(h);
        const layout = try n.readLayout(g.a, h);
        defer layout.deinit(g.a);
        const actual_guid = try n.guid(g.a, layout.header.Anonymous.Gpt.DiskId);
        if (!std.mem.eql(u8, actual_guid, owner.guid)) return error.DiskGuidChanged;
        for (d.partitions) |p| if (p.partition_uuid != null and std.mem.eql(u8, p.partition_uuid.?, owner.data_uuid)) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(g.io, try g.a.print("{s}pizza-sentinel.bin", .{p.path orelse return error.VolumeMissing}), g.a, .limited(512 * 1024 * 1024));
            if (bytes.len != 2 * MIB) return error.SentinelSizeChanged;
            return g.a.dupe(u8, &u.hash(bytes));
        };
        return error.SentinelMissing;
    }
    pub fn volume(g: Guest, c: wmi.Connection, number: u64, offset: u64) !wmi.Object {
        const until = n.k.GetTickCount64() + 30000;
        while (n.k.GetTickCount64() < until) {
            var parts = try c.query(g.a, try g.a.print("SELECT * FROM MSFT_Partition WHERE DiskNumber = {d} AND Offset = {d}", .{ number, offset }));
            defer parts.deinit();
            if (try parts.next()) |p| {
                defer p.deinit();
                var volumes = try c.query(g.a, try g.a.print("ASSOCIATORS OF {{{s}}} WHERE AssocClass = MSFT_PartitionToVolume", .{(try p.text(g.a, "__RELPATH")) orelse return error.PartitionPathMissing}));
                defer volumes.deinit();
                if (try volumes.next()) |v| return v;
            }
            n.k.Sleep(100);
        }
        return error.VolumeTimeout;
    }
    pub fn setup(g: *Guest) !void {
        const apt = try wmi.Apartment.init(&g.native.failure);
        defer apt.deinit();
        const c = try wmi.Connection.init(g.a, wmi.STORAGE_NAMESPACE, &g.native.failure);
        defer c.deinit();
        const disk = try Platform.owned(g, c);
        defer disk.deinit();
        if (try disk.number("PartitionStyle") != 0 or try disk.number("NumberOfPartitions") != 0) return error.NonemptyTargetRejected;
        const number = try disk.number("Number");
        var privilege = try n.Privilege.enable(.volume);
        defer privilege.deinit();
        (try c.method(g.a, disk, "Initialize", &.{.{ .name = n.wideLiteral("PartitionStyle"), .value = .{ .uint32 = 2 } }})).deinit();
        for ([_]u64{ 32 * MIB, 544 * MIB }, 0..) |offset, i| {
            const current = try Platform.owned(g, c);
            defer current.deinit();
            (try c.method(g.a, current, "CreatePartition", &.{
                .{ .name = n.wideLiteral("Size"), .value = .{ .uint64 = 512 * MIB } },                                 .{ .name = n.wideLiteral("Offset"), .value = .{ .uint64 = offset } },
                .{ .name = n.wideLiteral("GptType"), .value = .{ .text = "{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}" } }, .{ .name = n.wideLiteral("AssignDriveLetter"), .value = .{ .boolean = false } },
            })).deinit();
            const v = try Platform.volume(g.*, c, number, offset);
            defer v.deinit();
            (try c.method(g.a, v, "Format", &.{ .{ .name = n.wideLiteral("FileSystem"), .value = .{ .text = if (i == 0) "FAT32" else "NTFS" } }, .{ .name = n.wideLiteral("FileSystemLabel"), .value = .{ .text = if (i == 0) "PizzaESP" else "PizzaKeep" } }, .{ .name = n.wideLiteral("Full"), .value = .{ .boolean = false } }, .{ .name = n.wideLiteral("Force"), .value = .{ .boolean = false } } })).deinit();
            if (i == 0) {
                // Formatting a basic-data volume first exposes a stable volume
                // GUID. Convert only our new partition to ESP through Win32.
                const owned_disk = try Platform.owned(g, c);
                defer owned_disk.deinit();
                const h = try n.open(g.a, (try owned_disk.text(g.a, "Path")).?, n.GENERIC_READ | n.GENERIC_WRITE);
                defer n.close(h);
                const layout = try n.readLayout(g.a, h);
                defer layout.deinit(g.a);
                const api = n.win32.system.ioctl;
                var found = false;
                for (@constCast(layout.entries)) |*entry| if (entry.StartingOffset.QuadPart == @as(i64, @intCast(offset))) {
                    entry.Anonymous.Gpt.PartitionType = n.win32.zig.Guid.initString("c12a7328-f81f-11d2-ba4b-00a0c93ec93b");
                    entry.RewritePartition = 1;
                    found = true;
                };
                if (!found) return error.EspMissing;
                var returned: u32 = 0;
                const size = @offsetOf(api.DRIVE_LAYOUT_INFORMATION_EX, "PartitionEntry") + layout.entries.len * @sizeOf(api.PARTITION_INFORMATION_EX);
                if (n.k.DeviceIoControl(h, api.IOCTL_DISK_SET_DRIVE_LAYOUT_EX, layout.memory.ptr, @intCast(size), null, 0, &returned, null) == 0) return error.EspTypeChangeFailed;
                if (n.k.FlushFileBuffers(h) == 0) return error.DiskFlushFailed;
                if (n.k.DeviceIoControl(h, api.IOCTL_DISK_UPDATE_PROPERTIES, null, 0, null, 0, &returned, null) == 0) return error.DiskRefreshFailed;
            } else {
                const bytes = try g.a.alloc(u8, 2 * MIB);
                g.io.random(bytes);
                const f = try std.Io.Dir.cwd().createFile(g.io, try g.a.print("{s}pizza-sentinel.bin", .{(try v.text(g.a, "Path")) orelse return error.VolumeMissing}), .{ .exclusive = true });
                defer f.close(g.io);
                try f.writeStreamingAll(g.io, bytes);
                try f.sync(g.io);
            }
        }
        const s = try g.snapshot();
        for (s.disks) |d| {
            const h = n.open(g.a, d.path, 0) catch continue;
            defer n.close(h);
            if (try n.deviceNumber(h) != number) continue;
            const l = try n.readLayout(g.a, h);
            defer l.deinit(g.a);
            for (d.partitions) |p| if (try proto.byteCount(p.offset) == 544 * MIB) {
                try g.save("owned-disk.json", Owned{ .serial = g.serial, .wwn = g.wwn, .number = @intCast(number), .guid = try n.guid(g.a, l.header.Anonymous.Gpt.DiskId), .data_uuid = p.partition_uuid orelse return error.PartitionUuidMissing });
                try g.save("baseline.json", .{ .identity = d.identity, .layout = try layouts(g.a, d), .hash = try g.fileHash(d) });
                return;
            };
        }
        return error.TargetMissing;
    }
    pub fn edit(g: Guest, request: *editor.Request, initial: editor.Result) !editor.Result {
        var result = initial;
        var free: ?editor.Region = null;
        for (result.regions) |r| if (r.free and try proto.byteCount(r.offset) >= 1056 * MIB and try proto.byteCount(r.length) > 1024 * MIB) {
            free = r;
            break;
        };
        const label = try g.a.print("Pz{s}", .{g.case});
        request.layout = result.draft.layout;
        request.command = .{ .kind = .add_left, .partition_id = (free orelse return error.FreeRegionMissing).id, .filesystem = .ntfs, .name = label };
        result = try g.pizza(editor.Result, "plan", request.*, "add");
        const selected = result.selected orelse return error.SelectionMissing;
        request.layout = result.draft.layout;
        request.command = .{ .kind = .resize, .partition_id = selected, .length = "268435456" };
        request.review = true;
        return g.pizza(editor.Result, "plan", request.*, "plan");
    }
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--service")) return @import("agent.zig").dispatch(init);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--install-agent")) {
        return @import("agent.zig").install(init, args[0]) catch |err| {
            const path = try std.fs.path.join(a, &.{ std.fs.path.dirname(args[0]).?, "agent-install-error.txt" });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = try a.print("{s}: Win32={d}\n", .{ @errorName(err), @backingInt(n.k.GetLastError()) }) });
            return err;
        };
    }
    var parsed = try cli.Guest.parse(a, args[1..]);
    defer parsed.deinit();
    if (parsed.args.help != 0) return cli.help(init.io, cli.Guest);
    const positional = parsed.positionals;
    var g: Guest = .{ .a = a, .io = init.io, .work = positional[1].?, .serial = positional[2].?, .wwn = positional[3].?, .case = positional[4].? };
    if (!@import("core/platform/windows/session/security.zig").elevated()) return error.ElevatedWindowsRequired;
    const action = positional[0].?;
    if (action == .install) {
        try std.Io.Dir.cwd().createDir(g.io, g.work, .default_dir);
        const source = std.fs.path.dirname(args[0]) orelse return error.ArtifactDirectoryMissing;
        var dir = try std.Io.Dir.cwd().openDir(g.io, source, .{ .iterate = true });
        defer dir.close(g.io);
        var walk = try dir.walk(a);
        defer walk.deinit();
        while (try walk.next(g.io)) |entry| switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(g.io, try g.path(entry.path)),
            .file => try dir.copyFile(entry.path, std.Io.Dir.cwd(), try g.path(entry.path), g.io, .{}),
            else => return error.UnsupportedArtifactType,
        };
    } else if (action == .collect) {
        try g.collect();
    } else if (action == .servicing or action == .freeze) {
        const status = if (action == .freeze) try @import("servicing.zig").freeze() else try @import("servicing.zig").inspect();
        try g.save(if (action == .freeze) "update-policy.json" else "servicing.json", status);
        try std.Io.File.stdout().writeStreamingAll(init.io, try a.print("PZ_SERVICING:{s}\n", .{try std.json.Stringify.valueAlloc(a, status, .{})}));
    } else if (action == .probe) {
        try Platform.awaitInventory(g);
        const apt = try wmi.Apartment.init(&g.native.failure);
        defer apt.deinit();
        const c = try wmi.Connection.init(a, wmi.BITLOCKER_NAMESPACE, &g.native.failure);
        defer c.deinit();
        var provider = try c.query(a, "SELECT * FROM Win32_EncryptableVolume");
        defer provider.deinit();
        if (try provider.next()) |obj| obj.deinit();
        const sac_available = if (std.Io.Dir.cwd().statFile(init.io, "C:\\Windows\\System32\\sacsess.exe", .{})) |_| true else |_| false;
        const os_connection = try wmi.Connection.init(a, "ROOT\\CIMV2", &g.native.failure);
        defer os_connection.deinit();
        var os_query = try os_connection.query(a, "SELECT Version, BuildNumber, Caption FROM Win32_OperatingSystem");
        defer os_query.deinit();
        const os = (try os_query.next()) orelse return error.OperatingSystemMissing;
        defer os.deinit();
        try g.save("capabilities.json", .{ .sac_available = sac_available, .bitlocker_wmi = true, .version = try os.text(a, "Version"), .build = try os.text(a, "BuildNumber"), .caption = try os.text(a, "Caption") });
    } else if (action == .setup) {
        Platform.setup(&g) catch |err| {
            var buffer: [2304]u8 = undefined;
            std.debug.print("{s}\n", .{g.native.failure.message(&buffer, err)});
            return err;
        };
    } else if (action == .native) {
        try g.runNative();
    } else if (action == .plan) {
        try g.plan();
    } else if (action == .prepare) {
        try g.prepare();
    } else if (action == .reboot) {
        try g.reboot();
    } else if (action == .verify) {
        try g.verify();
    } else if (action == .shutdown or action == .restart) {
        var privilege = try n.Privilege.enable(.shutdown);
        defer privilege.deinit();
        if (n.win32.advapi32.InitiateSystemShutdownExW(null, null, if (action == .restart) 3 else 0, 0, if (action == .restart) 1 else 0, @bitCast(@as(u32, 0x80040000))) == 0) return error.ShutdownFailed;
    } else return error.UnknownAction;
    try std.Io.File.stdout().writeStreamingAll(init.io, "{\"ok\":true}\n");
}
