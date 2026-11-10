//! Durable handoff of an offline-compiled maintenance session. Storage and image
//! trust are platform ports; this module owns ordering, binding and completion.
//! It neither compiles physical programs nor accepts paths from web requests.
const std = @import("std");
const proto = @import("proto");
const uefi = @import("uefi.zig");
pub const Digest = [32]u8;
pub const MAX_MANIFEST_BYTES = 256 * 1024 * 1024;
pub const File = enum { image, manifest, lease, receipt, request, anchor };
/// Application-facing port. The platform owns trusted artifacts, its protected
/// pending record, ESP admission and the actual reboot mechanism.
pub const Controller = struct {
    context: *anyopaque,
    prepare: *const fn (*anyopaque, std.mem.Allocator, std.Io, proto.wire.InventorySnapshot, proto.wire.ValidatedPlan) anyerror!proto.wire.MaintenanceSession,
    reboot: *const fn (*anyopaque, std.mem.Allocator, std.Io, []const u8, []const u8) anyerror!proto.wire.MaintenanceSession,
    complete: *const fn (*anyopaque, std.mem.Allocator, std.Io, ?[]const u8) anyerror!proto.wire.CompletionReceipt,
    pending: *const fn (*anyopaque) anyerror!bool,
    cancel: ?*const fn (*anyopaque, std.mem.Allocator, std.Io, []const u8, ?[]const u8) anyerror!?proto.wire.MaintenanceSession = null,
};
pub const Store = struct {
    context: *anyopaque,
    /// Publish must reserve real space, sync bytes and publication metadata.
    /// read() rechecks the device and the file's allocation/ownership evidence.
    /// All allocations must be finalized before the manifest's FAT allocation
    /// proof is captured; publication may not change that frozen FAT layout.
    publish: *const fn (*anyopaque, std.Io, File, []const u8) anyerror!void,
    read: *const fn (*anyopaque, std.mem.Allocator, std.Io, File) anyerror!?[]const u8,
};
pub const Binding = struct {
    session: Digest,
    payload_digest: Digest,
    payload_bytes: u64,
    disk_identity: Digest,
    image_digest: Digest,

    pub fn encode(self: Binding) ![144]u8 {
        if (self.payload_bytes == 0 or self.payload_bytes > MAX_MANIFEST_BYTES or
            std.mem.allEqual(u8, &self.session, 0) or std.mem.allEqual(u8, &self.disk_identity, 0) or
            std.mem.allEqual(u8, &self.image_digest, 0)) return error.InvalidBootBinding;
        var bytes: [144]u8 = undefined;
        @memcpy(bytes[0..8], "PZBIND01");
        @memcpy(bytes[8..40], &self.session);
        @memcpy(bytes[40..72], &self.payload_digest);
        std.mem.writeInt(u64, bytes[72..80], self.payload_bytes, .little);
        @memcpy(bytes[80..112], &self.disk_identity);
        @memcpy(bytes[112..144], &self.image_digest);
        return bytes;
    }
    pub fn decode(bytes: []const u8) !Binding {
        if (bytes.len != 144 or !std.mem.eql(u8, bytes[0..8], "PZBIND01")) return error.InvalidBootBinding;
        const value: Binding = .{ .session = bytes[8..40].*, .payload_digest = bytes[40..72].*, .payload_bytes = std.mem.readInt(u64, bytes[72..80], .little), .disk_identity = bytes[80..112].*, .image_digest = bytes[112..144].* };
        _ = try value.encode();
        return value;
    }
    pub fn require(self: Binding, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables) !void {
        const actual = try vars.get(a, io, .pizza_session) orelse return error.MissingBootBinding;
        if (!std.mem.eql(u8, actual, &try self.encode())) return error.BootBindingChanged;
    }
    pub fn install(self: Binding, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables) !void {
        const bytes = try self.encode();
        if (try vars.get(a, io, .pizza_session)) |actual| {
            if (!std.mem.eql(u8, actual, &bytes)) return error.AnotherMaintenanceSessionExists;
        } else try vars.set(a, io, .pizza_session, &bytes);
    }
};
pub fn digest(bytes: []const u8) Digest {
    var out: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

pub const ReceiptEnvelope = struct { session: Digest, disk_identity: Digest, bytes: []const u8 };
/// Matching on-disk envelope is produced by pizza-maint's ESP receipt sink.
/// Checksums prove complete publication; parseCompletion still binds all five
/// identities to the host's protected pending record.
pub fn decodeReceiptEnvelope(bytes: []const u8) !ReceiptEnvelope {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..8], "PZRCPT01")) return error.InvalidCompletionReceiptEnvelope;
    const size = std.mem.readInt(u32, bytes[8..12], .little);
    const block = std.mem.readInt(u32, bytes[12..16], .little);
    if (block < 4096 or block > 1024 * 1024 or !std.math.isPowerOfTwo(block) or size == 0 or size > 65536 or
        bytes.len != block + std.mem.alignForward(u64, 65536, block)) return error.InvalidCompletionReceiptEnvelope;
    const header = bytes[0..block];
    const body = bytes[block..];
    if (!std.mem.eql(u8, header[header.len - 32 ..], &digest(header[0 .. header.len - 32])) or
        !std.mem.eql(u8, header[80..112], &digest(body[0..size])) or
        !std.mem.allEqual(u8, header[112 .. header.len - 32], 0) or !std.mem.allEqual(u8, body[size..], 0)) return error.InvalidCompletionReceiptEnvelope;
    return .{ .session = header[16..48].*, .disk_identity = header[48..80].*, .bytes = body[0..size] };
}

/// Must be constructed by the trusted image/manifest producer, after image
/// provenance verification and offline compilation. A web request cannot supply
/// these bytes or approve its own image digest.
pub const Artifacts = struct {
    image: []const u8,
    trusted_image_digest: Digest,
    manifest: []const u8,
    binding: Binding,
    expected: proto.ReceiptIdentity,
    partition_number: u32,
    start_lba: u64,
    size_lba: u64,
    partition_guid: [16]u8,
    /// A platform-selected path beneath its admitted, private session directory.
    image_path: []const u8,
    slot: u16,
};
pub const Prepared = struct {
    version: u16 = 1,
    binding: Binding,
    expected: proto.ReceiptIdentity,
    lease: uefi.Lease,

    pub fn prepare(a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, store: Store, artifacts: Artifacts) !Prepared {
        const manifest_lease = try validateArtifacts(a, artifacts);
        // A durable lease is never recaptured after an interrupted firmware
        // update: that would mistake our armed order for the user's original.
        if (try store.read(store.context, a, io, .lease)) |bytes| {
            const previous = try load(a, bytes);
            try previous.matches(artifacts);
            if (!leaseEq(previous.lease, manifest_lease)) return error.PreparedSessionChanged;
            try previous.verify(a, io, store);
            if (try store.read(store.context, a, io, .receipt)) |receipt| {
                _ = try proto.parseCompletion(a, receipt, previous.expected);
                return error.SessionAlreadyCompleted;
            }
            try previous.binding.install(a, io, vars);
            return previous;
        }
        if (try vars.get(a, io, .pizza_session) != null) return error.AnotherMaintenanceSessionExists;
        const option = try uefi.loadOption(a, artifacts.partition_number, artifacts.start_lba, artifacts.size_lba, artifacts.partition_guid, artifacts.image_path);
        const saved: Prepared = .{ .binding = artifacts.binding, .expected = artifacts.expected, .lease = try uefi.Lease.capture(a, io, vars, artifacts.slot, option) };
        if (!leaseEq(saved.lease, manifest_lease)) return error.PreparedSessionChanged;
        try publishChecked(a, io, store, .image, artifacts.image);
        try publishChecked(a, io, store, .manifest, artifacts.manifest);
        const bytes = try std.json.Stringify.valueAlloc(a, saved, .{});
        try publishChecked(a, io, store, .lease, bytes);
        // No firmware write precedes durable/read-back image, manifest and lease.
        try saved.binding.install(a, io, vars);
        return saved;
    }
    fn matches(self: Prepared, artifacts: Artifacts) !void {
        if (!std.meta.eql(self.binding, artifacts.binding)) return error.PreparedSessionChanged;
        inline for (comptime std.meta.fieldNames(proto.ReceiptIdentity)) |key| {
            if (!std.mem.eql(u8, @field(self.expected, key), @field(artifacts.expected, key))) return error.PreparedSessionChanged;
        }
        if (self.lease.slot != artifacts.slot) return error.PreparedSessionChanged;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const option = try uefi.loadOption(arena.allocator(), artifacts.partition_number, artifacts.start_lba, artifacts.size_lba, artifacts.partition_guid, artifacts.image_path);
        if (!std.mem.eql(u8, option, self.lease.option)) return error.PreparedSessionChanged;
    }
    pub fn load(a: std.mem.Allocator, bytes: []const u8) !Prepared {
        if (bytes.len > 1024 * 1024) return error.PreparedSessionTooLarge;
        const saved = try std.json.parseFromSliceLeaky(Prepared, a, bytes, .{});
        if (saved.version != 1) return error.UnsupportedPreparedSession;
        try saved.validate();
        return saved;
    }
    fn validate(self: Prepared) !void {
        _ = try self.binding.encode();
        inline for (comptime std.meta.fieldNames(proto.ReceiptIdentity)) |key| _ = try proto.hexDigest(@field(self.expected, key));
        if (!std.mem.eql(u8, &try proto.hexDigest(self.expected.id), &self.binding.session) or
            !std.mem.eql(u8, &try proto.hexDigest(self.expected.disk_identity), &self.binding.disk_identity) or
            !std.mem.eql(u8, &try proto.hexDigest(self.expected.image_digest), &self.binding.image_digest)) return error.PreparedSessionChanged;
        if (self.lease.original_order.len == 0 or self.lease.original_order.len > 8192 or self.lease.original_order.len % 2 != 0 or self.lease.option.len < 12 or self.lease.option.len > 65536) return error.InvalidBootLease;
        if (self.lease.original_next) |next| if (next.len != 2) return error.InvalidBootLease;
    }
    pub fn verify(self: Prepared, a: std.mem.Allocator, io: std.Io, store: Store) !void {
        try self.validate();
        const image = try store.read(store.context, a, io, .image) orelse return error.MaintenanceImageMissing;
        if (!std.mem.eql(u8, &digest(image), &self.binding.image_digest)) return error.MaintenanceImageChanged;
        const payload = try store.read(store.context, a, io, .manifest) orelse return error.SessionManifestMissing;
        if (payload.len != self.binding.payload_bytes or !std.mem.eql(u8, &digest(payload), &self.binding.payload_digest)) return error.SessionManifestChanged;
        const saved = try load(a, try store.read(store.context, a, io, .lease) orelse return error.PreparedSessionMissing);
        if (!std.meta.eql(saved.binding, self.binding) or saved.lease.slot != self.lease.slot or
            !std.mem.eql(u8, saved.lease.option, self.lease.option) or
            !std.mem.eql(u8, saved.lease.original_order, self.lease.original_order) or
            !optionalEq(saved.lease.original_next, self.lease.original_next)) return error.PreparedSessionChanged;
        inline for (comptime std.meta.fieldNames(proto.ReceiptIdentity)) |key| {
            if (!std.mem.eql(u8, @field(saved.expected, key), @field(self.expected, key))) return error.PreparedSessionChanged;
        }
    }
    pub fn arm(self: Prepared, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, store: Store) !void {
        try self.verify(a, io, store);
        try self.binding.require(a, io, vars);
        try self.lease.arm(a, io, vars);
    }
    /// Import only after maintenance removed its binding and restored the saved
    /// settings. Never repair firmware based on an unauthenticated receipt file.
    pub fn complete(self: Prepared, a: std.mem.Allocator, io: std.Io, vars: uefi.Variables, store: Store) !proto.wire.CompletionReceipt {
        try self.verify(a, io, store);
        if (try vars.get(a, io, .pizza_session) != null) return error.MaintenanceStillOwnsBoot;
        const next = try vars.get(a, io, .next);
        // Firmware consumes BootNext before returning to the host OS. An absent
        // one-shot value is legitimate even if the saved lease had BootNext.
        const order = try vars.get(a, io, .order) orelse return error.BootRestorationIncomplete;
        const restored = self.lease.restoredOrder(a, order) catch return error.BootRestorationIncomplete;
        if (!std.mem.eql(u8, order, restored) or
            (next != null and !optionalEq(next, self.lease.original_next)) or
            try vars.get(a, io, .{ .boot = self.lease.slot }) != null) return error.BootRestorationIncomplete;
        const bytes = try store.read(store.context, a, io, .receipt) orelse return error.NoCompletionReceipt;
        return proto.parseCompletion(a, bytes, self.expected);
    }
};
fn optionalEq(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |x| b != null and std.mem.eql(u8, x, b.?) else b == null;
}
fn leaseEq(a: uefi.Lease, b: uefi.Lease) bool {
    return a.slot == b.slot and std.mem.eql(u8, a.option, b.option) and
        std.mem.eql(u8, a.original_order, b.original_order) and optionalEq(a.original_next, b.original_next);
}
fn publishChecked(a: std.mem.Allocator, io: std.Io, store: Store, file: File, bytes: []const u8) !void {
    try store.publish(store.context, io, file, bytes);
    const actual = try store.read(store.context, a, io, file) orelse return error.StagedArtifactMissing;
    if (!std.mem.eql(u8, actual, bytes)) return error.StagedArtifactReadbackMismatch;
}
fn validateArtifacts(a: std.mem.Allocator, artifacts: Artifacts) !uefi.Lease {
    if (artifacts.image.len == 0 or !std.mem.eql(u8, &digest(artifacts.image), &artifacts.trusted_image_digest) or
        !std.mem.eql(u8, &artifacts.trusted_image_digest, &artifacts.binding.image_digest)) return error.MaintenanceImageChanged;
    if (artifacts.manifest.len != artifacts.binding.payload_bytes or !std.mem.eql(u8, &digest(artifacts.manifest), &artifacts.binding.payload_digest)) return error.SessionManifestChanged;
    const p: Prepared = .{ .binding = artifacts.binding, .expected = artifacts.expected, .lease = .{ .slot = artifacts.slot, .option = "placeholder!", .original_order = &.{ 1, 0 }, .original_next = null } };
    try p.validate();
    // The original boot lease is covered by the manifest's firmware-pinned
    // digest. Never trust an independently editable ESP copy on a retry.
    const bytes = artifacts.manifest;
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "PZMAN001")) return error.InvalidSessionManifest;
    const json_bytes = std.mem.readInt(u32, bytes[8..12], .little);
    if (json_bytes == 0 or json_bytes > 4 * 1024 * 1024 or json_bytes > bytes.len - 24) return error.InvalidSessionManifest;
    var total: u64 = 24 + @as(u64, json_bytes);
    for (0..3) |i| {
        const length = std.mem.readInt(u32, bytes[12 + i * 4 ..][0..4], .little);
        if (length == 0) return error.InvalidSessionManifest;
        total += length;
    }
    if (total != bytes.len) return error.InvalidSessionManifest;
    const Header = struct { version: u16, session: Digest, approved_plan: Digest, image: Digest, anchor: struct { disk_identity: Digest }, lease: uefi.Lease };
    const header = try std.json.parseFromSliceLeaky(Header, a, bytes[24..][0..json_bytes], .{ .ignore_unknown_fields = true });
    if (header.version != 1 or !std.mem.eql(u8, &header.session, &artifacts.binding.session) or
        !std.mem.eql(u8, &header.image, &artifacts.binding.image_digest) or
        !std.mem.eql(u8, &header.anchor.disk_identity, &artifacts.binding.disk_identity) or
        !std.mem.eql(u8, &header.approved_plan, &try proto.hexDigest(artifacts.expected.plan_digest))) return error.PreparedSessionChanged;
    return header.lease;
}

const MemoryStore = struct {
    a: std.mem.Allocator,
    files: [6]?[]const u8 = @splat(null),
    writes: usize = 0,
    fail_at: ?usize = null,
    corrupt: ?File = null,
    fn port(self: *MemoryStore) Store {
        return .{ .context = self, .publish = publish, .read = read };
    }
    fn publish(ctx: *anyopaque, _: std.Io, file: File, bytes: []const u8) !void {
        const self: *MemoryStore = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        if (self.fail_at == self.writes) return error.SimulatedSyncFailure;
        self.files[@backingInt(file)] = try self.a.dupe(u8, bytes);
    }
    fn read(ctx: *anyopaque, a: std.mem.Allocator, _: std.Io, file: File) !?[]const u8 {
        const self: *MemoryStore = @ptrCast(@alignCast(ctx));
        if (self.corrupt == file) return try a.dupe(u8, "corrupt");
        return if (self.files[@backingInt(file)]) |bytes| try a.dupe(u8, bytes) else null;
    }
};
fn fixture(a: std.mem.Allocator) !Artifacts {
    const image = "verified maintenance image";
    const option = try uefi.loadOption(a, 1, 2048, 65536, @splat(3), "\\EFI\\Pizza\\maint.efi");
    const json = try std.json.Stringify.valueAlloc(a, .{ .version = @as(u16, 1), .session = @as(Digest, @splat(1)), .approved_plan = try proto.hexDigest("abababababababababababababababababababababababababababababababab"), .image = digest(image), .anchor = .{ .disk_identity = @as(Digest, @splat(2)) }, .lease = uefi.Lease{ .slot = 0x5049, .option = option, .original_order = &.{ 1, 0, 2, 0 }, .original_next = &.{ 2, 0 } } }, .{});
    const manifest = try a.alloc(u8, 24 + json.len + 3);
    @memcpy(manifest[0..8], "PZMAN001");
    std.mem.writeInt(u32, manifest[8..12], @intCast(json.len), .little);
    for (0..3) |i| std.mem.writeInt(u32, manifest[12 + i * 4 ..][0..4], 1, .little);
    @memcpy(manifest[24..][0..json.len], json);
    @memset(manifest[24 + json.len ..], 0);
    const binding: Binding = .{ .session = @splat(1), .disk_identity = @splat(2), .image_digest = digest(image), .payload_digest = digest(manifest), .payload_bytes = manifest.len };
    return .{ .image = image, .trusted_image_digest = binding.image_digest, .manifest = manifest, .binding = binding, .expected = .{ .id = try a.dupe(u8, &std.fmt.bytesToHex(binding.session, .lower)), .disk_identity = try a.dupe(u8, &std.fmt.bytesToHex(binding.disk_identity, .lower)), .image_digest = try a.dupe(u8, &std.fmt.bytesToHex(binding.image_digest, .lower)), .plan_digest = "abababababababababababababababababababababababababababababababab", .program_digest = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd" }, .partition_number = 1, .start_lba = 2048, .size_lba = 65536, .partition_guid = @splat(3), .image_path = "\\EFI\\Pizza\\maint.efi", .slot = 0x5049 };
}

test "firmware remains untouched after any staging failure or changed image" {
    for (1..4) |cut| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var vars: uefi.MemoryVariables = .{ .a = a };
        var store: MemoryStore = .{ .a = a, .fail_at = cut };
        try std.testing.expectError(error.SimulatedSyncFailure, Prepared.prepare(a, std.testing.io, vars.vars(), store.port(), try fixture(a)));
        try std.testing.expectEqual(0, vars.writes);
        store.fail_at = null;
        _ = try Prepared.prepare(a, std.testing.io, vars.vars(), store.port(), try fixture(a));
        try std.testing.expectEqual(1, vars.writes); // pin only; reboot is separate
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vars: uefi.MemoryVariables = .{ .a = a };
    var store: MemoryStore = .{ .a = a };
    var bad = try fixture(a);
    bad.image = "changed maintenance image";
    try std.testing.expectError(error.MaintenanceImageChanged, Prepared.prepare(a, std.testing.io, vars.vars(), store.port(), bad));
    try std.testing.expectEqual(0, vars.writes);
    try std.testing.expectEqual(0, store.writes);
}

test "saved lease survives every interrupted firmware write without recapture" {
    for (1..5) |cut| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var vars: uefi.MemoryVariables = .{ .a = a, .fail_after = cut };
        var store: MemoryStore = .{ .a = a };
        const artifacts = try fixture(a);
        _ = Prepared.prepare(a, std.testing.io, vars.vars(), store.port(), artifacts) catch |err| if (err != error.SimulatedFirmwareInterruption) return err;
        const saved = try Prepared.load(a, store.files[@backingInt(File.lease)].?);
        saved.arm(a, std.testing.io, vars.vars(), store.port()) catch |err| if (err != error.SimulatedFirmwareInterruption) return err;
        vars.fail_after = null;
        const resumed = try Prepared.prepare(a, std.testing.io, vars.vars(), store.port(), artifacts);
        try resumed.arm(a, std.testing.io, vars.vars(), store.port());
        try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, resumed.lease.original_order);
        try std.testing.expectEqualSlices(u8, &.{ 0x49, 0x50, 1, 0, 2, 0 }, vars.order.?);
    }
}

test "completion refuses active maintenance, changed files, foreign firmware and mismatched receipt" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vars: uefi.MemoryVariables = .{ .a = a };
    var store: MemoryStore = .{ .a = a };
    const saved = try Prepared.prepare(a, std.testing.io, vars.vars(), store.port(), try fixture(a));
    try saved.arm(a, std.testing.io, vars.vars(), store.port());
    try std.testing.expectError(error.MaintenanceStillOwnsBoot, saved.complete(a, std.testing.io, vars.vars(), store.port()));
    store.corrupt = .manifest;
    try std.testing.expectError(error.SessionManifestChanged, saved.arm(a, std.testing.io, vars.vars(), store.port()));
    store.corrupt = null;
    const receipt: proto.wire.CompletionReceipt = .{ .version = proto.API_VERSION, .id = saved.expected.id, .plan_digest = saved.expected.plan_digest, .program_digest = saved.expected.program_digest, .disk_identity = saved.expected.disk_identity, .image_digest = saved.expected.image_digest, .outcome = .completed, .message = "verified" };
    store.files[@backingInt(File.receipt)] = try std.json.Stringify.valueAlloc(a, receipt, .{});
    try saved.lease.restore(a, std.testing.io, vars.vars());
    try vars.vars().set(a, std.testing.io, .pizza_session, null);
    vars.next = null; // the return boot consumed the original one-shot entry
    try std.testing.expectEqual(.completed, (try saved.complete(a, std.testing.io, vars.vars(), store.port())).outcome);
    const writes_before = vars.writes;
    try std.testing.expectError(error.SessionAlreadyCompleted, Prepared.prepare(a, std.testing.io, vars.vars(), store.port(), try fixture(a)));
    try std.testing.expectEqual(writes_before, vars.writes);
    vars.order = &.{ 7, 0 };
    try std.testing.expectEqual(.completed, (try saved.complete(a, std.testing.io, vars.vars(), store.port())).outcome);
    vars.order = saved.lease.original_order;
    var wrong = receipt;
    wrong.disk_identity = saved.expected.plan_digest;
    store.files[@backingInt(File.receipt)] = try std.json.Stringify.valueAlloc(a, wrong, .{});
    try std.testing.expectError(error.CompletionReceiptIdentityMismatch, saved.complete(a, std.testing.io, vars.vars(), store.port()));
}

test "staged bytes and saved boot lease cannot be substituted before arming" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vars: uefi.MemoryVariables = .{ .a = a };
    var store: MemoryStore = .{ .a = a, .corrupt = .image };
    try std.testing.expectError(error.StagedArtifactReadbackMismatch, Prepared.prepare(a, std.testing.io, vars.vars(), store.port(), try fixture(a)));
    try std.testing.expectEqual(0, vars.writes);
    store.corrupt = null;
    const artifacts = try fixture(a);
    const saved = try Prepared.prepare(a, std.testing.io, vars.vars(), store.port(), artifacts);
    var forged = saved;
    forged.lease.original_order = &.{ 9, 0 };
    store.files[@backingInt(File.lease)] = try std.json.Stringify.valueAlloc(a, forged, .{});
    try std.testing.expectError(error.PreparedSessionChanged, Prepared.prepare(a, std.testing.io, vars.vars(), store.port(), artifacts));
    try std.testing.expectError(error.PreparedSessionChanged, saved.arm(a, std.testing.io, vars.vars(), store.port()));
    try std.testing.expectEqual(1, vars.writes);
}

test "host decodes the maintenance receipt envelope and rejects torn publication" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, 4096 + 65536);
    defer a.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], "PZRCPT01");
    std.mem.writeInt(u32, bytes[8..12], 2, .little);
    std.mem.writeInt(u32, bytes[12..16], 4096, .little);
    @memset(bytes[16..48], 1);
    @memset(bytes[48..80], 2);
    @memcpy(bytes[4096..4098], "{}");
    @memcpy(bytes[80..112], &digest("{}"));
    @memcpy(bytes[4064..4096], &digest(bytes[0..4064]));
    const envelope = try decodeReceiptEnvelope(bytes);
    try std.testing.expectEqualStrings("{}", envelope.bytes);
    try std.testing.expectEqual(@as(Digest, @splat(1)), envelope.session);
    bytes[4097] = '!';
    try std.testing.expectError(error.InvalidCompletionReceiptEnvelope, decodeReceiptEnvelope(bytes));
    bytes[4097] = '}';
    bytes[bytes.len - 1] = 1;
    try std.testing.expectError(error.InvalidCompletionReceiptEnvelope, decodeReceiptEnvelope(bytes));
    try std.testing.expectError(error.InvalidCompletionReceiptEnvelope, decodeReceiptEnvelope(bytes[0..4096]));
}
