//! Shared durable maintenance state machine. Platform ports own OS security,
//! device access, firmware handles, protected records and the reboot mechanism.
const std = @import("std");
const proto = @import("proto");
const h = proto.Handoff;
const w = proto.wire;
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
            request: h.Request,
            receipt: ?w.CompletionReceipt = null,
        };
        pub fn controller(self: *Self) boot.Controller {
            return .{ .context = self, .prepare = prepare, .reboot = reboot, .complete = complete, .pending = pending, .cancel = cancel };
        }
        fn load(a: std.mem.Allocator, store: *Store) !?Pending {
            const bytes = try store.read(a, PENDING_KEY) orelse return null;
            return try decodePending(a, bytes);
        }
        fn decodePending(a: std.mem.Allocator, bytes: []const u8) !Pending {
            const value = try std.json.parseFromSliceLeaky(Pending, a, bytes, .{});
            if (value.version != 1) return error.IncompatibleHandoff;
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
        fn binding(request: h.Request, bytes: []const u8) !boot.Binding {
            return .{ .session = try proto.hexDigest(request.id), .payload_digest = boot.digest(bytes), .payload_bytes = bytes.len, .disk_identity = try proto.hexDigest(request.draft.disk_identity), .image_digest = try proto.hexDigest(request.image_digest) };
        }
        fn lease(value: h.Lease) uefi.Lease {
            return .{ .slot = value.slot, .original_order = value.original_order, .original_next = value.original_next, .option = value.option };
        }
        fn project(value: Pending) w.MaintenanceSession {
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
        fn staged(a: std.mem.Allocator, io: std.Io, request: h.Request, create: bool) !Esp {
            const snapshot = try Platform.query(a, io);
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
            if (bytes.len == 0 or bytes.len % h.BLOCK_SIZE != 0 or !std.mem.eql(u8, &boot.digest(bytes), &self.image_digest)) return error.MaintenanceImageChanged;
            return bytes;
        }
        fn verify(a: std.mem.Allocator, io: std.Io, esp: *Esp, request: h.Request) !void {
            const port = esp.store();
            const image_bytes = try port.read(port.context, a, io, .image) orelse return error.MaintenanceImageMissing;
            if (!std.mem.eql(u8, &boot.digest(image_bytes), &try proto.hexDigest(request.image_digest))) return error.MaintenanceImageChanged;
            const actual = try port.read(port.context, a, io, .request) orelse return error.HandoffRequestMissing;
            if (!std.mem.eql(u8, actual, try request.encode(a))) return error.HandoffRequestChanged;
        }
        fn prepare(ctx: *anyopaque, a: std.mem.Allocator, io: std.Io, snapshot: w.InventorySnapshot, validated: w.ValidatedPlan) !w.MaintenanceSession {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var store = try Platform.records(a);
            defer store.deinit();
            var fw = try Platform.openFirmware(io, true);
            defer Platform.closeFirmware(&fw, io);
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
                } else value = try newRequest(a, io, snapshot, validated, vars, self.image_digest);
            } else value = try newRequest(a, io, snapshot, validated, vars, self.image_digest);
            if (try vars.get(a, io, .pizza_session) != null) return error.AnotherMaintenanceSessionExists;
            // Protected pending state precedes allocations so a failed preparation can
            // reuse exactly this session and cannot lose ownership of partial files.
            try save(a, &store, value);
            const bytes = try image(self, a, io);
            const request_bytes = try value.request.encode(a);
            var esp = try staged(a, io, value.request, true);
            defer esp.close(io);
            try esp.ensureReserved(.image, bytes.len);
            try esp.ensureReserved(.request, request_bytes.len);
            try esp.ensureReserved(.manifest, h.MANIFEST_BYTES);
            try esp.ensureReserved(.anchor, h.RECOVERY_BYTES);
            try esp.ensureReserved(.receipt, h.BLOCK_SIZE + 65536);
            const port = esp.store();
            try port.publish(port.context, io, .image, bytes);
            try port.publish(port.context, io, .request, request_bytes);
            try verify(a, io, &esp, value.request);
            value.phase = .prepared;
            try save(a, &store, value);
            try (try binding(value.request, request_bytes)).install(a, io, vars);
            return project(value);
        }
        fn newRequest(a: std.mem.Allocator, io: std.Io, snapshot: w.InventorySnapshot, validated: w.ValidatedPlan, vars: uefi.Variables, image_digest: boot.Digest) !Pending {
            const disk = try @import("../execution/state.zig").disk(snapshot, validated.draft.disk_identity);
            var candidate: ?w.HostPartition = null;
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
            const request: h.Request = .{ .id = id, .plan_digest = validated.digest, .image_digest = try a.dupe(u8, &std.fmt.bytesToHex(image_digest, .lower)), .inventory = snapshot, .draft = validated.draft, .esp = .{ .number = number, .uuid = uuid, .offset = offset, .length = length }, .lease = .{ .slot = captured.slot, .original_order = captured.original_order, .original_next = captured.original_next, .option = captured.option } };
            try request.validate();
            return .{ .phase = .preparing, .request = request };
        }
        fn reboot(_: *anyopaque, a: std.mem.Allocator, io: std.Io, id: []const u8, approved: []const u8) !w.MaintenanceSession {
            var store = try Platform.records(a);
            defer store.deinit();
            var value = try load(a, &store) orelse return error.PreparedSessionMissing;
            if (!std.mem.eql(u8, value.request.id, id) or !std.mem.eql(u8, value.request.plan_digest, approved)) return error.SessionApprovalMismatch;
            if (value.phase != .prepared and value.phase != .armed) return error.InvalidSessionTransition;
            var esp = try staged(a, io, value.request, false);
            defer esp.close(io);
            try verify(a, io, &esp, value.request);
            var fw = try Platform.openFirmware(io, true);
            defer Platform.closeFirmware(&fw, io);
            try (try binding(value.request, try value.request.encode(a))).require(a, io, fw.variables());
            try lease(value.request.lease).arm(a, io, fw.variables());
            value.phase = .armed;
            try save(a, &store, value);
            try Platform.reboot(a, io);
            return project(value);
        }
        fn complete(_: *anyopaque, a: std.mem.Allocator, io: std.Io, requested: ?[]const u8) !w.CompletionReceipt {
            var store = try Platform.records(a);
            defer store.deinit();
            var value = try load(a, &store) orelse return error.NoCompletionReceipt;
            if (requested) |id| if (!std.mem.eql(u8, id, value.request.id)) return error.SessionApprovalMismatch;
            var fw = try Platform.openFirmware(io, true);
            defer Platform.closeFirmware(&fw, io);
            const vars = fw.variables();
            const pinned = try vars.get(a, io, .pizza_session);
            if (value.phase == .completed) {
                if (pinned) |bytes| {
                    const terminal = try h.Terminal.decode(a, bytes);
                    _ = try terminal.receipt(a, value.request, try value.request.encode(a), try std.json.Stringify.valueAlloc(a, value.receipt.?, .{}));
                    try vars.set(a, io, .pizza_session, null);
                }
                releaseCompleted(a, io, value.request);
                return value.receipt orelse return error.NoCompletionReceipt;
            }
            const terminal = try h.Terminal.decode(a, pinned orelse return error.MissingBootBinding);
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
            const order = try vars.get(a, io, .order) orelse return error.BootRestorationIncomplete;
            const next = try vars.get(a, io, .next);
            if (!std.mem.eql(u8, order, try saved_lease.restoredOrder(order)) or
                (next != null and (value.request.lease.original_next == null or !std.mem.eql(u8, next.?, value.request.lease.original_next.?))) or
                try vars.get(a, io, .{ .boot = value.request.lease.slot }) != null) return error.BootRestorationIncomplete;
            value.phase = .completed;
            value.receipt = result;
            try save(a, &store, value);
            // Report persistence/readback precedes clearing the retained terminal pin.
            try vars.set(a, io, .pizza_session, null);
            esp.releaseReservations() catch |err| std.log.warn("Completed maintenance staging cleanup: {t}", .{err});
            return result;
        }
        fn releaseCompleted(a: std.mem.Allocator, io: std.Io, request: h.Request) void {
            var esp = staged(a, io, request, false) catch return;
            defer esp.close(io);
            esp.releaseReservations() catch |err| std.log.warn("Completed maintenance staging cleanup: {t}", .{err});
        }
        fn pending(ctx: *anyopaque) !bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            var store = try Platform.records(arena.allocator());
            defer store.deinit();
            if (try load(arena.allocator(), &store)) |value| if (value.phase != .completed and value.phase != .cancelled) return true;
            var fw = Platform.openFirmware(self.io, false) catch |err| switch (err) {
                error.UefiRequired => return false,
                else => return err,
            };
            defer Platform.closeFirmware(&fw, self.io);
            return try fw.variables().get(arena.allocator(), self.io, .pizza_session) != null;
        }

        /// The original request pin proves that offline execution has not been admitted.
        /// A compiled or terminal pin belongs to recovery and cannot be cancelled here.
        fn cancel(_: *anyopaque, a: std.mem.Allocator, io: std.Io, id: []const u8, approved: ?[]const u8) !?w.MaintenanceSession {
            var store = try Platform.records(a);
            defer store.deinit();
            var value = try load(a, &store) orelse return null;
            if (!std.mem.eql(u8, id, value.request.id)) return null;
            if (!std.mem.eql(u8, approved orelse return error.MissingApproval, value.request.plan_digest)) return error.SessionApprovalMismatch;
            if (value.phase == .completed) return error.InvalidSessionTransition;
            var fw = try Platform.openFirmware(io, true);
            defer Platform.closeFirmware(&fw, io);
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
            return project(value);
        }
    };
}

const TestPlatform = struct {
    pub const Store = struct {};
    pub const Esp = struct {
        pub const bootPath = @import("staging.zig").bootPath;
    };
    pub fn verifyDisk(_: std.mem.Allocator, _: std.Io, _: w.HostDisk) !void {}
};

test "maintenance request captures byte geometry and restores the original firmware lease" {
    if (comptime !@hasDecl(proto, "Handoff")) return error.SkipZigTest;
    const Subject = Maintenance(TestPlatform);
    for ([_]u32{ 512, 4096 }) |sector| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        const part: w.HostPartition = .{ .id = id, .name = "ESP", .offset = "33554432", .length = "536870912", .slot = 0, .partition_uuid = "11111111111111111111111111111111", .type_guid = &@import("../planning/identity.zig").Gpt.ESP, .filesystem = .vfat, .encryption = .none };
        const disk: w.HostDisk = .{ .path = "/dev/test-only", .identity = id, .capacity = "4294967296", .sector_size = sector, .model = "fixture", .read_only = false, .partition_table = "gpt", .partitions = &.{part} };
        const snapshot: w.InventorySnapshot = .{ .version = proto.API_VERSION, .snapshot_id = id, .platform = .linux, .disks = &.{disk} };
        const validated: w.ValidatedPlan = .{ .version = proto.API_VERSION, .digest = id, .executable = false, .offline_validation_required = true, .draft = .{ .version = proto.API_VERSION, .snapshot_id = id, .disk_identity = id } };
        var memory: uefi.MemoryVariables = .{ .a = a };
        const value = try Subject.newRequest(a, std.testing.io, snapshot, validated, memory.vars(), @splat(2));
        try std.testing.expectEqual(0, memory.writes);
        try std.testing.expectEqual(@as(u64, 33554432), value.request.esp.offset);
        try std.testing.expectEqual(@as(u64, 536870912), value.request.esp.length);
        const encoded = try value.request.encode(a);
        const decoded = try h.Request.decode(a, encoded);
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
