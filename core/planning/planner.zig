//! Intent normalization, structural validation and capability-based scheduling.
//! Filesystem probes are supplied by the caller; this module never calls OS APIs.
const std = @import("std");
const proto = @import("proto");
const wire = proto.wire;
/// Domain admission limits, shared by editing and validation.
pub const Limits = struct {
    pub const PARTITIONS = 4096;
    pub const INTENTS = 16384;
    pub const LABEL_BYTES = 1024;
    pub const MINIMUM_SECTOR_BYTES = 512;
};
fn original(disk: wire.HostDisk, id: []const u8) ?wire.HostPartition {
    for (disk.partitions) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}
fn has(intents: []const wire.PlanIntent, id: []const u8, kind: wire.IntentKind) bool {
    for (intents) |i| if (std.mem.eql(u8, i.partition_id, id) and i.kind == kind) return true;
    return false;
}
fn diagnostic(a: std.mem.Allocator, list: *std.ArrayList(wire.Diagnostic), code: []const u8, message: []const u8, id: ?[]const u8) !void {
    try list.append(a, .{ .code = code, .message = message, .partition_id = id, .severity = .@"error" });
}
pub fn optimize(a: std.mem.Allocator, input: []const wire.PlanIntent) ![]const wire.PlanIntent {
    if (input.len > Limits.INTENTS) return error.PlanTooLarge;
    var out: std.ArrayList(wire.PlanIntent) = .empty;
    for (input) |intent| {
        var handled = false;
        if (intent.kind == .resize or intent.kind == .move or intent.kind == .label or intent.kind == .delete) {
            var j = out.items.len;
            while (j != 0) {
                j -= 1;
                const old = &out.items[j];
                if (old.kind == .barrier or old.kind == .copy or old.kind == .format or old.kind == .delete) break;
                if (!std.mem.eql(u8, old.partition_id, intent.partition_id)) continue;
                if (old.kind == .create and intent.kind != .move) {
                    if (intent.kind == .delete) {
                        _ = out.orderedRemove(j);
                    } else {
                        if (intent.length) |n| old.length = n;
                        if (intent.offset) |n| old.offset = n;
                        if (intent.label) |label| old.label = label;
                    }
                    handled = true;
                } else if (old.kind == intent.kind) {
                    old.* = intent;
                    handled = true;
                }
                break;
            }
        }
        if (!handled) try out.append(a, intent);
    }
    return out.toOwnedSlice(a);
}
pub fn validate(a: std.mem.Allocator, inventory: wire.InventorySnapshot, draft: wire.PlanDraft, filesystems: anytype) !wire.ValidatedPlan {
    if (draft.version != proto.API_VERSION or inventory.version != proto.API_VERSION) return error.UnsupportedProtocolVersion;
    _ = try proto.hexDigest(draft.snapshot_id);
    _ = try proto.hexDigest(draft.disk_identity);
    if (draft.layout.len > Limits.PARTITIONS or draft.intents.len > Limits.INTENTS) return error.PlanTooLarge;
    var diags: std.ArrayList(wire.Diagnostic) = .empty;
    if (!std.mem.eql(u8, inventory.snapshot_id, draft.snapshot_id)) try diagnostic(a, &diags, "stale_inventory", "Disk geometry changed; refresh the inventory before preparing.", null);
    const disk = for (inventory.disks) |d| {
        if (d.identity) |id| if (std.mem.eql(u8, id, draft.disk_identity)) break d;
    } else return error.DiskIdentityNotFound;
    if (disk.read_only) try diagnostic(a, &diags, "read_only", "The disk is read-only.", null);
    if (!std.mem.eql(u8, disk.partition_table orelse "", "gpt")) try diagnostic(a, &diags, "gpt_required", "Execution requires a validated GPT partition table.", null);
    const capacity = try proto.byteCount(disk.capacity);
    if (disk.sector_size < Limits.MINIMUM_SECTOR_BYTES or !std.math.isPowerOfTwo(disk.sector_size)) return error.InvalidSectorSize;
    const usable_start = if (disk.usable_offset) |n| try proto.byteCount(n) else 0;
    const usable_length = if (disk.usable_length) |n| try proto.byteCount(n) else 0;
    const usable_end = try std.math.add(u64, usable_start, usable_length);
    if (usable_length == 0 or usable_end > capacity) try diagnostic(a, &diags, "unknown_usable_range", "GPT usable bounds could not be established.", null);
    for (draft.intents) |intent| {
        if (intent.partition_id.len == 0 or intent.partition_id.len > 128) return error.InvalidPartitionIdentity;
        if (intent.offset) |n| _ = try proto.byteCount(n);
        if (intent.length) |n| if (try proto.byteCount(n) == 0) return error.InvalidByteCount;
        if (intent.kind == .copy) try diagnostic(a, &diags, "intent_not_supported", "This host operation does not yet have a validated compiler.", intent.partition_id);
    }
    var destroyed: std.ArrayList([]const u8) = .empty;
    for (draft.layout, 0..) |p, i| {
        if (p.name.len > Limits.LABEL_BYTES or !std.unicode.utf8ValidateSlice(p.name) or std.mem.indexOfScalar(u8, p.name, 0) != null) return error.InvalidLabel;
        const prior = original(disk, p.id);
        if (prior == null or (if (prior) |v| !std.mem.eql(u8, v.name, p.name) else false) or has(draft.intents, p.id, .format)) {
            if (p.filesystem) |fs| if (!try filesystems.validLabel(a, fs, p.name)) {
                try diagnostic(a, &diags, "filesystem_label_rejected", "The filesystem backend could not validate this label; check the label and filesystem plugin.", p.id);
            };
        }
        const start = try proto.byteCount(p.offset);
        const length = try proto.byteCount(p.length);
        const end = try std.math.add(u64, start, length);
        if (length == 0 or start % disk.sector_size != 0 or length % disk.sector_size != 0 or start < usable_start or end > usable_end) try diagnostic(a, &diags, "invalid_partition_range", "Partition must fit the usable disk area and align to logical sectors.", p.id);
        for (draft.layout[0..i]) |other| {
            if (std.mem.eql(u8, other.id, p.id) or (other.slot != null and p.slot != null and other.slot.? == p.slot.?)) try diagnostic(a, &diags, "duplicate_partition", "Partition identity or slot is duplicated.", p.id);
            const os = try proto.byteCount(other.offset);
            const oe = try std.math.add(u64, os, try proto.byteCount(other.length));
            if (start < oe and os < end) try diagnostic(a, &diags, "overlapping_partitions", "Partition ranges overlap.", p.id);
        }
        if (original(disk, p.id)) |old| {
            if ((p.slot != null and p.slot != old.slot) or
                !std.mem.eql(u8, p.attributes, old.attributes orelse "0") or
                (p.partition_uuid != null and !std.mem.eql(u8, p.partition_uuid.?, old.partition_uuid orelse "")) or
                (p.type_guid != null and !std.mem.eql(u8, p.type_guid.?, old.type_guid orelse "")))
                try diagnostic(a, &diags, "gpt_metadata_change_unsupported", "The host backend does not apply changes to retained GPT identity, type, attributes or slot.", p.id);
            const geometry_changed = !std.mem.eql(u8, old.offset, p.offset) or !std.mem.eql(u8, old.length, p.length);
            const changed = geometry_changed or old.filesystem != p.filesystem or !p.retain_data or !std.mem.eql(u8, old.name, p.name);
            if (changed and (old.protected or old.encryption != .none)) try diagnostic(a, &diags, "protected_partition", "Boot anchors and encrypted or unidentified volumes cannot be changed.", p.id);
            if (geometry_changed and !has(draft.intents, p.id, .resize) and !has(draft.intents, p.id, .move)) try diagnostic(a, &diags, "missing_geometry_intent", "Geometry changes need an explicit resize or move intent.", p.id);
            if (!std.mem.eql(u8, old.name, p.name) and !has(draft.intents, p.id, .label)) try diagnostic(a, &diags, "missing_label_intent", "Label changes require an explicit intent.", p.id);
            if (old.filesystem != p.filesystem or !p.retain_data) {
                if (p.retain_data or !has(draft.intents, p.id, .format)) try diagnostic(a, &diags, "format_confirmation_required", "Filesystem replacement must explicitly discard existing contents.", p.id);
                try destroyed.append(a, p.id);
            }
            if (changed) {
                for (old.capabilities) |cap| if (cap.backend == .maintenance and cap.support == .unavailable and ((cap.operation == .resize and geometry_changed) or (cap.operation == .format and !p.retain_data))) try diagnostic(a, &diags, cap.reason, "The filesystem backend does not permit this operation.", p.id);
            }
        } else {
            if (p.retain_data or !has(draft.intents, p.id, .create)) try diagnostic(a, &diags, "invalid_new_partition", "New partitions need a create intent and cannot claim retained data.", p.id);
            if (p.partition_uuid == null or p.type_guid == null) try diagnostic(a, &diags, "missing_gpt_identity", "New partitions require GPT type and partition UUIDs.", p.id);
            if (p.partition_uuid) |uuid| {
                const computed = @import("identity.zig").partition(a, draft.disk_identity, uuid) catch "";
                if (!std.mem.eql(u8, computed, p.id)) try diagnostic(a, &diags, "invalid_partition_identity", "New partition identity must match its disk and GPT UUID.", p.id);
            }
            if (p.type_guid) |type_id| {
                _ = @import("identity.zig").guid(type_id) catch {
                    try diagnostic(a, &diags, "invalid_type_guid", "New partition type must be a nonzero GPT GUID in raw byte order.", p.id);
                    continue;
                };
            }
            if (p.slot != null or !std.mem.eql(u8, p.attributes, "0")) try diagnostic(a, &diags, "new_gpt_metadata_unsupported", "The host allocator cannot honor an explicit new slot or nonzero attributes.", p.id);
        }
    }
    for (disk.partitions) |old| {
        const found = for (draft.layout) |p| {
            if (std.mem.eql(u8, p.id, old.id)) break true;
        } else false;
        if (!found) {
            if (old.protected or old.encryption != .none) try diagnostic(a, &diags, "protected_partition", "This partition cannot be deleted.", old.id);
            if (!has(draft.intents, old.id, .delete)) try diagnostic(a, &diags, "delete_confirmation_required", "Deleting an existing partition needs an explicit delete intent.", old.id);
            try destroyed.append(a, old.id);
        }
    }
    const normalized = try optimize(a, draft.intents);
    for (normalized) |intent| {
        if (intent.kind == .barrier) continue;
        const desired: ?wire.DesiredPartition = for (draft.layout) |p| {
            if (std.mem.eql(u8, p.id, intent.partition_id)) break p;
        } else null;
        if (intent.kind == .delete) {
            if (desired != null) try diagnostic(a, &diags, "contradictory_delete", "A deleted partition is still present in the final layout.", intent.partition_id);
            continue;
        }
        const p = desired orelse {
            try diagnostic(a, &diags, "missing_intent_target", "An operation references a partition absent from the final layout.", intent.partition_id);
            continue;
        };
        var mismatch = false;
        switch (intent.kind) {
            .create => mismatch = original(disk, p.id) != null or intent.offset == null or intent.length == null or intent.filesystem == null or intent.filesystem != p.filesystem or p.retain_data,
            .resize => mismatch = intent.length == null,
            .move => mismatch = intent.offset == null,
            .format => mismatch = intent.filesystem == null or intent.filesystem != p.filesystem or p.retain_data,
            else => {},
        }
        if (intent.label) |label| if (!std.mem.eql(u8, label, p.name)) {
            mismatch = true;
        };
        if (intent.offset) |n| if (!std.mem.eql(u8, n, p.offset)) {
            mismatch = true;
        };
        if (intent.length) |n| if (!std.mem.eql(u8, n, p.length)) {
            mismatch = true;
        };
        if (mismatch) try diagnostic(a, &diags, "intent_layout_mismatch", "Reviewed operation parameters disagree with the final layout.", p.id);
    }
    const body = try std.json.Stringify.valueAlloc(a, .{ .draft = draft, .operations = normalized }, .{});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &hash, .{});
    const stages = try schedule(a, disk, draft, normalized, filesystems);
    var valid = true;
    for (diags.items) |d| if (d.severity == .@"error") {
        valid = false;
    };
    if (stages.maintenance.len != 0) try diags.append(a, .{ .code = "maintenance_preflight_required", .severity = .info, .message = "Remaining steps require a verified reboot handoff. Host changes cannot begin until the complete route is prepared." });
    return .{ .version = proto.API_VERSION, .digest = try a.dupe(u8, &std.fmt.bytesToHex(hash, .lower)), .executable = valid and stages.maintenance.len == 0, .offline_validation_required = stages.maintenance.len != 0, .diagnostics = try diags.toOwnedSlice(a), .operations = normalized, .host_operations = stages.host, .maintenance_operations = stages.maintenance, .rollback_scope = if (stages.maintenance.len != 0) .maintenance_only else .none, .destructive_partitions = try destroyed.toOwnedSlice(a), .draft = draft };
}

test "normalization respects data-version barriers and cancels unused creations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const output = try optimize(a, &.{ .{ .kind = .resize, .partition_id = "a", .length = "1024" }, .{ .kind = .resize, .partition_id = "a", .length = "2048" }, .{ .kind = .copy, .partition_id = "b", .source_id = "a" }, .{ .kind = .resize, .partition_id = "a", .length = "4096" }, .{ .kind = .create, .partition_id = "new", .length = "512" }, .{ .kind = .resize, .partition_id = "new", .length = "1024" }, .{ .kind = .delete, .partition_id = "new" } });
    try std.testing.expectEqual(3, output.len);
    try std.testing.expectEqualStrings("2048", output[0].length.?);
    try std.testing.expectEqual(.copy, output[1].kind);
    try std.testing.expectEqualStrings("4096", output[2].length.?);
}

const Stages = struct { host: []const wire.PlanIntent, maintenance: []const wire.PlanIntent };
fn desiredFor(draft: wire.PlanDraft, id: []const u8) ?wire.DesiredPartition {
    for (draft.layout) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}
fn hostCap(p: wire.HostPartition, op: wire.IntentKind) bool {
    for (p.capabilities) |c| if (c.operation == op and c.backend == .host and c.support == .available) return true;
    return false;
}
fn freeRange(parts: []const wire.HostPartition, skip: []const u8, p: wire.DesiredPartition) !bool {
    const start = try proto.byteCount(p.offset);
    const end = try std.math.add(u64, start, try proto.byteCount(p.length));
    for (parts) |other| {
        if (std.mem.eql(u8, other.id, skip) or std.mem.eql(u8, other.length, "0")) continue;
        const os = try proto.byteCount(other.offset);
        const oe = try std.math.add(u64, os, try proto.byteCount(other.length));
        if (start < oe and os < end) return false;
    }
    return true;
}
fn schedule(a: std.mem.Allocator, disk: wire.HostDisk, draft: wire.PlanDraft, ops: []const wire.PlanIntent, filesystems: anytype) !Stages {
    var work: std.ArrayList(wire.HostPartition) = .empty;
    try work.appendSlice(a, disk.partitions);
    const done = try a.alloc(bool, ops.len);
    @memset(done, false);
    var host: std.ArrayList(wire.PlanIntent) = .empty;
    var progress = true;
    while (progress) {
        progress = false;
        for (ops, 0..) |op, i| {
            if (done[i]) continue;
            if (op.kind == .barrier) break;
            const old: ?usize = for (work.items, 0..) |p, j| {
                if (std.mem.eql(u8, p.id, op.partition_id)) break j;
            } else null;
            const p = desiredFor(draft, op.partition_id);
            if (op.kind == .copy or op.kind == .move) continue;
            var allowed = false;
            if (op.kind == .create) {
                if (p) |v| {
                    if (v.filesystem) |f| allowed = try freeRange(work.items, "", v) and try filesystems.canFs(a, f, .create, false, false);
                }
            } else if (old) |j| {
                const before = work.items[j];
                if (!hostCap(before, op.kind)) continue;
                if (op.kind == .delete) allowed = before.mountpoints.len == 0 else if (p) |v| {
                    const mounted = before.mountpoints.len != 0;
                    if (op.kind == .resize) {
                        if (!std.mem.eql(u8, before.offset, v.offset)) continue;
                        if (before.filesystem) |f| allowed = try freeRange(work.items, before.id, v) and try filesystems.canFs(a, f, .resize, mounted, try proto.byteCount(v.length) < try proto.byteCount(before.length));
                    } else if (op.kind == .format or op.kind == .label) {
                        if (!std.mem.eql(u8, before.offset, v.offset) or !std.mem.eql(u8, before.length, v.length)) continue;
                        if (v.filesystem) |f| allowed = try filesystems.canFs(a, f, op.kind, mounted, false);
                    }
                }
            }
            if (!allowed) continue;
            try host.append(a, op);
            done[i] = true;
            progress = true;
            if (op.kind == .delete) {
                work.items[old.?].length = "0";
            } else if (p) |v| {
                if (old) |j| {
                    work.items[j].offset = v.offset;
                    work.items[j].length = v.length;
                } else try work.append(a, .{ .id = v.id, .offset = v.offset, .length = v.length, .name = v.name, .filesystem = v.filesystem, .encryption = .none });
            }
        }
    }
    var maintenance: std.ArrayList(wire.PlanIntent) = .empty;
    for (ops, 0..) |op, i| if (!done[i] and op.kind != .barrier) {
        try maintenance.append(a, op);
    };
    return .{ .host = try host.toOwnedSlice(a), .maintenance = try maintenance.toOwnedSlice(a) };
}
