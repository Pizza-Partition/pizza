//! Shared durable maintenance state machine. Platform ports own OS security,
//! device access, firmware handles, protected records and the reboot mechanism.
const std = @import("std");
const proto = @import("proto");
const Handoff = proto.Handoff;
const wire = proto.wire;
const boot = @import("session.zig");
const uefi = @import("uefi.zig");

pub fn Maintenance(comptime Platform: type) type {
    return struct {
        const PENDING_KEY = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
        const Self = @This();
        const Esp = Platform.Esp;
        const Store = Platform.Store;
        image_digest: boot.Digest,
        io: std.Io,
        const Pending = struct {
            version: u16 = 1,
            phase: enum { preparing, prepared, armed, completed, cancelled },
            request: Handoff.Request,
            receipt: ?wire.CompletionReceipt = null,
        };
        pub fn controller(self: *Self) boot.Controller {
            return .{ .context = self, .prepare = prepare, .reboot = reboot, .complete = complete, .pending = pending, .cancel = cancel };
        }
        fn load(a: std.mem.Allocator, store: *Store) !?Pending {
            const bytes = try store.read(a, PENDING_KEY) orelse return null;
            return decodePending(a, bytes) catch |err| {
                // A protected terminal record from an older request schema is
                // archival state. The independent firmware pin still prevents
                // admitting a new session until boot restoration has finished.
                if (try archivedTerminal(a, bytes)) {
                    std.log.info("Ignoring archived maintenance record with an older schema: {t}", .{err});
                    return null;
                }
                return err;
            };
        }
        fn archivedTerminal(a: std.mem.Allocator, bytes: []const u8) !bool {
            const value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
            if (value != .object) return false;
            const version = value.object.get("version") orelse return false;
            if (version != .integer or version.integer != 1) return false;
            const phase = value.object.get("phase") orelse return false;
            if (phase != .string) return false;
            const receipt = value.object.get("receipt") orelse .null;
            return (std.mem.eql(u8, phase.string, "cancelled") and receipt == .null) or
                (std.mem.eql(u8, phase.string, "completed") and receipt == .object);
        }
        fn decodePending(a: std.mem.Allocator, bytes: []const u8) !Pending {
            const value = try std.json.parseFromSliceLeaky(Pending, a, bytes, .{});
            if (value.version != 1) return error.IncompatibleHandoff;
            // Terminal records no longer authorize writes. A protocol version bump
            // must not turn a completed/cancelled session into a permanent lock.
            if (value.phase == .completed or value.phase == .cancelled) {
                if ((value.phase == .completed) != (value.receipt != null)) return error.InvalidPendingState;
                return value;
            }
            try value.request.validate();
            if ((value.phase == .completed) != (value.receipt != null)) return error.InvalidPendingState;
            if (value.receipt) |r| {
                _ = try proto.parseCompletion(a, try std.json.Stringify.valueAlloc(a, r, .{}), .{ .id = value.request.id, .plan_digest = value.request.plan_digest, .disk_identity = value.request.draft.disk_identity, .image_digest = value.request.image_digest, .program_digest = r.program_digest });
            }
            return value;
        }
        fn save(a: std.mem.Allocator, store: *Store, value: Pending) !void {
            const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
            try store.persist(PENDING_KEY, bytes);
            const readback = try store.read(a, PENDING_KEY) orelse return error.PreparedSessionMissing;
            if (!std.mem.eql(u8, bytes, readback)) return error.PreparedSessionChanged;
        }
        fn binding(request: Handoff.Request, bytes: []const u8) !boot.Binding {
            return .{ .session = try proto.hexDigest(request.id), .payload_digest = boot.digest(bytes), .payload_bytes = bytes.len, .disk_identity = try proto.hexDigest(request.draft.disk_identity), .image_digest = try proto.hexDigest(request.image_digest) };
        }
        fn lease(value: Handoff.Lease) uefi.Lease {
            return .{ .slot = value.slot, .original_order = value.original_order, .original_next = value.original_next, .option = value.option };
        }
        fn project(value: Pending) wire.MaintenanceSession {
            return .{ .version = proto.API_VERSION, .id = value.request.id, .plan_digest = value.request.plan_digest, .phase = switch (value.phase) {
                .preparing => .draft,
                .prepared => .prepared,
                .armed => .armed,
                .completed => .completed,
                .cancelled => .failed,
            }, .message = switch (value.phase) {
                .preparing => "Reserving maintenance files.",
                .prepared => "Request and boot image persisted. Reboot is ready.",
                .armed => "Maintenance boot enabled; System restart requested.",
                .completed => "Maintenance receipt imported.",
                .cancelled => "Maintenance preparation cancelled before offline execution admission.",
            } };
        }
        fn staged(a: std.mem.Allocator, io: std.Io, request: Handoff.Request, create: bool) !Esp {
            const snapshot = try Platform.inventory.query(a, io);
            const disk = try @import("../execution/state.zig").disk(snapshot, request.draft.disk_identity);
            const part = for (disk.partitions) |p| {
                const uuid = @import("../planning/identity.zig").guid(p.partition_uuid orelse continue) catch continue;
                if (std.mem.eql(u8, &uuid, &request.esp.uuid)) break p;
            } else return error.EspPartitionChanged;
            if (try proto.byteCount(part.offset) != request.esp.offset or try proto.byteCount(part.length) != request.esp.length) return error.EspPartitionChanged;
            return Esp.open(a, io, disk, part, request.id, create);
        }
        fn image(self: *Self, a: std.mem.Allocator, io: std.Io) ![]const u8 {
            const executable = try Platform.executable(a, io);
            const path = try std.fs.path.join(a, &.{ std.fs.path.dirname(executable) orelse return error.ExecutableUnavailable, "maint.efi" });
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(512 * 1024 * 1024));
            if (bytes.len == 0 or bytes.len % Handoff.BLOCK_SIZE != 0 or !std.mem.eql(u8, &boot.digest(bytes), &self.image_digest)) return error.MaintenanceImageChanged;
            return bytes;
        }
        fn verify(a: std.mem.Allocator, io: std.Io, esp: *Esp, request: Handoff.Request) !void {
            const port = esp.store();
            const image_bytes = try port.read(port.context, a, io, .image) orelse return error.MaintenanceImageMissing;
            if (!std.mem.eql(u8, &boot.digest(image_bytes), &try proto.hexDigest(request.image_digest))) return error.MaintenanceImageChanged;
            const actual = try port.read(port.context, a, io, .request) orelse return error.HandoffRequestMissing;
            if (!std.mem.eql(u8, actual, try request.encode(a))) return error.HandoffRequestChanged;
        }
        fn prepare(ctx: *anyopaque, a: std.mem.Allocator, io: std.Io, snapshot: wire.InventorySnapshot, validated: wire.ValidatedPlan) !wire.MaintenanceSession {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var store = try Store.openMaintenance(a);
            defer store.deinit();
            var fw = try Platform.Uefi.open(io, true);
            defer fw.close(io);
            try Platform.requireUnsigned(&fw, a, io);
            const vars = fw.variables();
            var value: Pending = undefined;
            if (try load(a, &store)) |previous| {
                if (previous.phase != .completed and previous.phase != .cancelled) {
                    if (!std.mem.eql(u8, previous.request.plan_digest, validated.digest)) return error.AnotherMaintenanceSessionExists;
                    value = previous;
                    if (previous.phase != .preparing) {
                        var esp = try staged(a, io, previous.request, false);
                        defer esp.close(io);
                        try verify(a, io, &esp, previous.request);
                        const pin = try binding(previous.request, try previous.request.encode(a));
                        if (previous.phase == .prepared) try pin.install(a, io, vars) else try pin.require(a, io, vars);
                        return project(previous);
                    }
                } else {
                    // A terminal session whose cleanup failed earlier must not keep
                    // its space while a new one reserves the same amount again.
                    releaseStaged(a, io, previous.request);
                    value = try newRequest(a, io, snapshot, validated, vars, self.image_digest);
                }
            } else value = try newRequest(a, io, snapshot, validated, vars, self.image_digest);
            if (try vars.get(a, io, .pizza_session) != null) return error.AnotherMaintenanceSessionExists;
            // Protected pending state precedes allocations so a failed preparation can
            // reuse exactly this session and cannot lose ownership of partial files.
            try save(a, &store, value);
            const bytes = try image(self, a, io);
            const request_bytes = try value.request.encode(a);
            var esp = try staged(a, io, value.request, true);
            defer esp.close(io);
            try esp.ensureCapacity(.{ bytes.len, request_bytes.len, Handoff.MANIFEST_BYTES, Handoff.RECOVERY_BYTES, Handoff.BLOCK_SIZE + 65536 });
            try esp.ensureReserved(.image, bytes.len);
            try esp.ensureReserved(.request, request_bytes.len);
            try esp.ensureReserved(.manifest, Handoff.MANIFEST_BYTES);
            try esp.ensureReserved(.anchor, Handoff.RECOVERY_BYTES);
            try esp.ensureReserved(.receipt, Handoff.BLOCK_SIZE + 65536);
            const port = esp.store();
            try port.publish(port.context, io, .image, bytes);
            try port.publish(port.context, io, .request, request_bytes);
            try verify(a, io, &esp, value.request);
            value.phase = .prepared;
            try save(a, &store, value);
            try (try binding(value.request, request_bytes)).install(a, io, vars);
            return project(value);
        }
        fn newRequest(a: std.mem.Allocator, io: std.Io, snapshot: wire.InventorySnapshot, validated: wire.ValidatedPlan, vars: uefi.Variables, image_digest: boot.Digest) !Pending {
            const disk = try @import("../execution/state.zig").disk(snapshot, validated.draft.disk_identity);
            var candidate: ?wire.HostPartition = null;
            for (disk.partitions) |p| {
                if (!std.mem.eql(u8, p.type_guid orelse "", &@import("../planning/identity.zig").Gpt.ESP)) continue;
                if (candidate != null) return error.AmbiguousEsp;
                candidate = p;
            }
            const part = candidate orelse return error.EspRequired;
            const uuid = try @import("../planning/identity.zig").guid(part.partition_uuid orelse return error.MissingPartitionIdentity);
            try Platform.verifyDisk(a, io, disk);
            var random: [32]u8 = undefined;
            io.random(&random);
            const id = try a.dupe(u8, &std.fmt.bytesToHex(random, .lower));
            const offset = try proto.byteCount(part.offset);
            const length = try proto.byteCount(part.length);
            if ((disk.sector_size != 512 and disk.sector_size != 4096) or offset % disk.sector_size != 0 or length % disk.sector_size != 0) return error.InvalidEspGeometry;
            const number = try std.math.add(u32, part.slot orelse return error.MissingPartitionIdentity, 1);
            const option = try uefi.loadOption(a, number, offset / disk.sector_size, length / disk.sector_size, uuid, try Esp.bootPath(a, id));
            const captured = try uefi.Lease.captureAvailable(a, io, vars, option);
            const request: Handoff.Request = .{ .id = id, .plan_digest = validated.digest, .image_digest = try a.dupe(u8, &std.fmt.bytesToHex(image_digest, .lower)), .inventory = snapshot, .draft = validated.draft, .esp = .{ .number = number, .uuid = uuid, .offset = offset, .length = length }, .lease = .{ .slot = captured.slot, .original_order = captured.original_order, .original_next = captured.original_next, .option = captured.option } };
            try request.validate();
            return .{ .phase = .preparing, .request = request };
        }
        fn reboot(_: *anyopaque, a: std.mem.Allocator, io: std.Io, id: []const u8, approved: []const u8) !wire.MaintenanceSession {
            var store = try Store.openMaintenance(a);
            defer store.deinit();
            var value = try load(a, &store) orelse return error.PreparedSessionMissing;
            if (!std.mem.eql(u8, value.request.id, id) or !std.mem.eql(u8, value.request.plan_digest, approved)) return error.SessionApprovalMismatch;
            if (value.phase != .prepared and value.phase != .armed) return error.InvalidSessionTransition;
            var esp = try staged(a, io, value.request, false);
            defer esp.close(io);
            try verify(a, io, &esp, value.request);
            {
                var fw = try Platform.Uefi.open(io, true);
                defer fw.close(io);
                try (try binding(value.request, try value.request.encode(a))).require(a, io, fw.variables());
                try lease(value.request.lease).arm(a, io, fw.variables());
            }
            value.phase = .armed;
            try save(a, &store, value);
            try Platform.power.reboot(a, io);
            return project(value);
        }
        fn complete(_: *anyopaque, a: std.mem.Allocator, io: std.Io, requested: ?[]const u8) !wire.CompletionReceipt {
            var store = try Store.openMaintenance(a);
            defer store.deinit();
            var value = try load(a, &store) orelse return error.NoCompletionReceipt;
            if (requested) |id| if (!std.mem.eql(u8, id, value.request.id)) return error.SessionApprovalMismatch;
            var fw = try Platform.Uefi.open(io, true);
            defer fw.close(io);
            const vars = fw.variables();
            const pinned = try vars.get(a, io, .pizza_session);
            if (value.phase == .completed) {
                if (pinned) |bytes| {
                    const terminal = try Handoff.Terminal.decode(a, bytes);
                    _ = try terminal.receipt(a, value.request, try value.request.encode(a), try std.json.Stringify.valueAlloc(a, value.receipt.?, .{}));
                    try vars.set(a, io, .pizza_session, null);
                }
                releaseStaged(a, io, value.request);
                return value.receipt orelse return error.NoCompletionReceipt;
            }
            const terminal = try Handoff.Terminal.decode(a, pinned orelse return error.MissingBootBinding);
            var esp = try staged(a, io, value.request, false);
            defer esp.close(io);
            try verify(a, io, &esp, value.request);
            const port = esp.store();
            const bytes = try port.read(port.context, a, io, .receipt) orelse return error.NoCompletionReceipt;
            const result = try terminal.receipt(a, value.request, try value.request.encode(a), bytes);
            // A durable authenticated terminal receipt also authorizes resuming an
            // interrupted boot restoration, without replaying offline disk operations.
            const saved_lease = lease(value.request.lease);
            try saved_lease.restore(a, io, vars);
            if (try vars.get(a, io, .{ .boot = value.request.lease.slot })) |option| {
                if (std.mem.eql(u8, option, value.request.lease.option)) return error.BootRestorationIncomplete;
            }
            value.phase = .completed;
            value.receipt = result;
            try save(a, &store, value);
            // Report persistence/readback precedes clearing the retained terminal pin.
            try vars.set(a, io, .pizza_session, null);
            esp.releaseReservations() catch |err| std.log.warn("Completed maintenance staging cleanup: {t}", .{err});
            return result;
        }
        /// Free the large staged files of a session that will never boot. Best
        /// effort: a terminal session must stay terminal even when its ESP is
        /// unreachable, so failures are logged and retried by the next prepare.
        fn releaseStaged(a: std.mem.Allocator, io: std.Io, request: Handoff.Request) void {
            var esp = staged(a, io, request, false) catch |err| {
                std.log.warn("Maintenance staging cleanup could not open the ESP: {t}", .{err});
                return;
            };
            defer esp.close(io);
            esp.releaseReservations() catch |err| std.log.warn("Maintenance staging cleanup: {t}", .{err});
        }
        fn pending(ctx: *anyopaque) !bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            var store = try Store.openMaintenance(arena.allocator());
            defer store.deinit();
            if (try load(arena.allocator(), &store)) |value| if (value.phase != .completed and value.phase != .cancelled) return true;
            var fw = Platform.Uefi.open(self.io, false) catch |err| switch (err) {
                error.UefiRequired => return false,
                else => return err,
            };
            defer fw.close(self.io);
            return try fw.variables().get(arena.allocator(), self.io, .pizza_session) != null;
        }

        /// The original request pin proves that offline execution has not been admitted.
        /// A compiled or terminal pin belongs to recovery and cannot be cancelled here.
        fn cancel(_: *anyopaque, a: std.mem.Allocator, io: std.Io, id: []const u8, approved: ?[]const u8) !?wire.MaintenanceSession {
            var store = try Store.openMaintenance(a);
            defer store.deinit();
            var value = try load(a, &store) orelse return null;
            if (!std.mem.eql(u8, id, value.request.id)) return null;
            if (!std.mem.eql(u8, approved orelse return error.MissingApproval, value.request.plan_digest)) return error.SessionApprovalMismatch;
            if (value.phase == .completed) return error.InvalidSessionTransition;
            var fw = try Platform.Uefi.open(io, true);
            defer fw.close(io);
            const vars = fw.variables();
            const pin = try vars.get(a, io, .pizza_session);
            if (value.phase == .armed and pin == null) return error.MissingBootBinding;
            if (pin != null) try (try binding(value.request, try value.request.encode(a))).require(a, io, vars);
            // Restore before committing cancellation. If interrupted, the original pin
            // remains and both the lease restore and this operation are retryable.
            try lease(value.request.lease).restore(a, io, vars);
            value.phase = .cancelled;
            try save(a, &store, value);
            if (pin != null) try vars.set(a, io, .pizza_session, null);
            // The session can no longer boot: return its space on the ESP.
            releaseStaged(a, io, value.request);
            return project(value);
        }
    };
}

const TestPlatform = struct {
    pub const Store = struct {};
    pub const Esp = struct {
        pub const bootPath = @import("staging.zig").bootPath;
    };
    pub fn verifyDisk(_: std.mem.Allocator, _: std.Io, _: wire.HostDisk) !void {}
};

test "maintenance request captures byte geometry and restores the original firmware lease" {
    if (comptime !@hasDecl(proto, "Handoff")) return error.SkipZigTest;
    const Subject = Maintenance(TestPlatform);
    for ([_]u32{ 512, 4096 }) |sector| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        const part: wire.HostPartition = .{ .id = id, .name = "ESP", .offset = "33554432", .length = "536870912", .slot = 0, .partition_uuid = "11111111111111111111111111111111", .type_guid = &@import("../planning/identity.zig").Gpt.ESP, .filesystem = .vfat, .encryption = .none };
        const disk: wire.HostDisk = .{ .path = "/dev/test-only", .identity = id, .capacity = "4294967296", .sector_size = sector, .model = "fixture", .read_only = false, .partition_table = "gpt", .partitions = &.{part} };
        const snapshot: wire.InventorySnapshot = .{ .version = proto.API_VERSION, .snapshot_id = id, .platform = .linux, .disks = &.{disk} };
        const validated: wire.ValidatedPlan = .{ .version = proto.API_VERSION, .digest = id, .executable = false, .offline_validation_required = true, .draft = .{ .version = proto.API_VERSION, .snapshot_id = id, .disk_identity = id } };
        var memory: uefi.MemoryVariables = .{ .a = a };
        const value = try Subject.newRequest(a, std.testing.io, snapshot, validated, memory.vars(), @splat(2));
        try std.testing.expectEqual(0, memory.writes);
        try std.testing.expectEqual(@as(u64, 33554432), value.request.esp.offset);
        try std.testing.expectEqual(@as(u64, 536870912), value.request.esp.length);
        const encoded = try value.request.encode(a);
        const decoded = try Handoff.Request.decode(a, encoded);
        try std.testing.expectEqualStrings(value.request.id, decoded.id);
        const pin = try Subject.binding(decoded, encoded);
        try pin.install(a, std.testing.io, memory.vars());
        try pin.require(a, std.testing.io, memory.vars());
        var foreign = pin;
        foreign.image_digest = @splat(3);
        try std.testing.expectError(error.BootBindingChanged, foreign.require(a, std.testing.io, memory.vars()));
        var invalid = value;
        invalid.phase = .completed;
        try std.testing.expectError(error.InvalidPendingState, Subject.decodePending(a, try std.json.Stringify.valueAlloc(a, invalid, .{})));
        memory.owned_slot = decoded.lease.slot;
        const saved = Subject.lease(decoded.lease);
        try saved.arm(a, std.testing.io, memory.vars());
        memory.next = null; // BootNext consumed by firmware.
        try saved.restore(a, std.testing.io, memory.vars());
        try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, memory.order.?);
        try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, memory.next.?);
        try std.testing.expect(memory.owned == null);
        var ambiguous = snapshot;
        var duplicate = disk;
        duplicate.partitions = &.{ part, part };
        ambiguous.disks = &.{duplicate};
        try std.testing.expectError(error.AmbiguousEsp, Subject.newRequest(a, std.testing.io, ambiguous, validated, memory.vars(), @splat(2)));
    }
}

/// In-memory ports for the whole state machine: a pending-record store, the
/// firmware variables, one inventory snapshot and an ESP that counts releases.
const MemoryPlatform = struct {
    var a: std.mem.Allocator = undefined;
    var record: ?[]const u8 = null;
    var memory: uefi.MemoryVariables = undefined;
    var snapshot: wire.InventorySnapshot = undefined;
    var released: usize = 0;
    var esp_available = true;
    fn reset(allocator: std.mem.Allocator, current: wire.InventorySnapshot) void {
        a = allocator;
        record = null;
        memory = .{ .a = allocator };
        snapshot = current;
        released = 0;
        esp_available = true;
    }
    pub const Store = struct {
        pub fn openMaintenance(_: std.mem.Allocator) !Store {
            return .{};
        }
        pub fn deinit(_: *Store) void {}
        pub fn read(_: *Store, allocator: std.mem.Allocator, _: []const u8) !?[]const u8 {
            return if (record) |bytes| try allocator.dupe(u8, bytes) else null;
        }
        pub fn persist(_: *Store, _: []const u8, bytes: []const u8) !void {
            record = try a.dupe(u8, bytes);
        }
    };
    pub const Uefi = struct {
        pub fn open(_: std.Io, _: bool) !Uefi {
            return .{};
        }
        pub fn close(_: *Uefi, _: std.Io) void {}
        pub fn variables(_: *Uefi) uefi.Variables {
            return memory.vars();
        }
    };
    pub const inventory = struct {
        pub fn query(_: std.mem.Allocator, _: std.Io) !wire.InventorySnapshot {
            return snapshot;
        }
    };
    pub const Esp = struct {
        pub const bootPath = @import("staging.zig").bootPath;
        pub fn open(_: std.mem.Allocator, _: std.Io, _: wire.HostDisk, _: wire.HostPartition, _: []const u8, _: bool) !Esp {
            return if (esp_available) .{} else error.EspMappingChanged;
        }
        pub fn close(_: *Esp, _: std.Io) void {}
        pub fn releaseReservations(_: *Esp) !void {
            released += 1;
        }
        pub fn ensureCapacity(_: *Esp, _: [5]u64) !void {}
        pub fn ensureReserved(_: *Esp, _: boot.File, _: u64) !void {}
        pub fn store(self: *Esp) boot.Store {
            return .{ .context = self, .read = readNothing, .publish = publishNothing };
        }
        fn readNothing(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: boot.File) anyerror!?[]const u8 {
            return null;
        }
        fn publishNothing(_: *anyopaque, _: std.Io, _: boot.File, _: []const u8) anyerror!void {}
    };
    pub fn verifyDisk(_: std.mem.Allocator, _: std.Io, _: wire.HostDisk) !void {}
    pub fn requireUnsigned(_: *Uefi, _: std.mem.Allocator, _: std.Io) !void {}
    pub fn executable(_: std.mem.Allocator, _: std.Io) ![]const u8 {
        return error.ExecutableUnavailable;
    }

    const ID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const PART: wire.HostPartition = .{ .id = ID, .name = "ESP", .offset = "33554432", .length = "536870912", .slot = 0, .partition_uuid = "11111111111111111111111111111111", .type_guid = &@import("../planning/identity.zig").Gpt.ESP, .filesystem = .vfat, .encryption = .none };
    const DISK: wire.HostDisk = .{ .path = "/dev/test-only", .identity = ID, .capacity = "4294967296", .sector_size = 512, .model = "fixture", .read_only = false, .partition_table = "gpt", .partitions = &.{PART} };
    const SNAPSHOT: wire.InventorySnapshot = .{ .version = proto.API_VERSION, .snapshot_id = ID, .platform = .linux, .disks = &.{DISK} };
    const PLAN: wire.ValidatedPlan = .{ .version = proto.API_VERSION, .digest = ID, .executable = false, .offline_validation_required = true, .draft = .{ .version = proto.API_VERSION, .snapshot_id = ID, .disk_identity = ID } };
    const Subject = Maintenance(MemoryPlatform);

    /// A session whose files are staged and whose pin is installed, not yet armed.
    fn prepared(allocator: std.mem.Allocator) !Subject.Pending {
        reset(allocator, SNAPSHOT);
        var value = try Subject.newRequest(allocator, std.testing.io, SNAPSHOT, PLAN, memory.vars(), @splat(2));
        value.phase = .prepared;
        var store: Store = .{};
        try Subject.save(allocator, &store, value);
        try (try Subject.binding(value.request, try value.request.encode(allocator))).install(allocator, std.testing.io, memory.vars());
        return value;
    }
};

test "cancelling a prepared session releases its ESP reservations" {
    if (comptime !@hasDecl(proto, "Handoff")) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try MemoryPlatform.prepared(a);
    var context: u8 = 0;
    const result = (try MemoryPlatform.Subject.cancel(&context, a, std.testing.io, value.request.id, value.request.plan_digest)).?;
    try std.testing.expectEqual(.failed, result.phase);
    try std.testing.expect(MemoryPlatform.memory.binding == null);
    try std.testing.expectEqual(1, MemoryPlatform.released);
}

test "terminal archival records survive request schema changes while active records fail closed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Subject = Maintenance(TestPlatform);
    try std.testing.expect(try Subject.archivedTerminal(a, "{\"version\":1,\"phase\":\"cancelled\",\"request\":{\"old_field\":true}}"));
    try std.testing.expect(try Subject.archivedTerminal(a, "{\"version\":1,\"phase\":\"completed\",\"receipt\":{\"old_field\":true}}"));
    try std.testing.expect(!try Subject.archivedTerminal(a, "{\"version\":1,\"phase\":\"armed\"}"));
    try std.testing.expect(!try Subject.archivedTerminal(a, "{\"version\":1,\"phase\":\"completed\",\"receipt\":null}"));
}

test "a cancellation that could not reach the ESP still completes, and the next prepare frees the files" {
    if (comptime !@hasDecl(proto, "Handoff")) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try MemoryPlatform.prepared(a);
    var subject: MemoryPlatform.Subject = .{ .image_digest = @splat(2), .io = std.testing.io };
    MemoryPlatform.esp_available = false;
    const cancelled = (try MemoryPlatform.Subject.cancel(&subject, a, std.testing.io, value.request.id, value.request.plan_digest)).?;
    try std.testing.expectEqual(.failed, cancelled.phase);
    try std.testing.expectEqual(0, MemoryPlatform.released);
    MemoryPlatform.esp_available = true;
    // The fixture has no maintenance image, so preparation stops after the cleanup.
    try std.testing.expectError(error.ExecutableUnavailable, MemoryPlatform.Subject.prepare(&subject, a, std.testing.io, MemoryPlatform.SNAPSHOT, MemoryPlatform.PLAN));
    try std.testing.expectEqual(1, MemoryPlatform.released);
}
