//! Host filesystem probes and capability-based scheduling over shared admission.
const std = @import("std");
const proto = @import("proto");
const wire = proto.wire;
const common = proto.plan_validation;
pub const Limits = common.Limits;
pub const optimize = common.optimize;
const original = common.original;
const diagnostic = common.diagnostic;
const has = common.has;
pub fn validate(a: std.mem.Allocator, inventory: wire.InventorySnapshot, draft: wire.PlanDraft, filesystems: anytype) !wire.ValidatedPlan {
    var base = try common.validate(a, inventory, draft);
    const disk = base.disk;
    var diags = base.diagnostics;
    for (draft.layout) |p| {
        const prior = original(disk, p.id);
        if (prior == null or (if (prior) |v| !std.mem.eql(u8, v.name, p.name) else false) or has(draft.intents, p.id, .format)) {
            if (p.filesystem) |fs| if (!try filesystems.validLabel(a, fs, p.name)) {
                try diagnostic(a, &diags, "filesystem_label_rejected", "The filesystem backend could not validate this label; check the label and filesystem plugin.", p.id);
            };
        }
        if (prior) |old| {
            if ((p.slot != null and p.slot != old.slot) or
                !std.mem.eql(u8, p.attributes, old.attributes orelse "0") or
                (p.partition_uuid != null and !std.mem.eql(u8, p.partition_uuid.?, old.partition_uuid orelse "")) or
                (p.type_guid != null and !std.mem.eql(u8, p.type_guid.?, old.type_guid orelse "")))
                try diagnostic(a, &diags, "gpt_metadata_change_unsupported", "The host backend does not apply changes to retained GPT identity, type, attributes or slot.", p.id);
        } else if (p.slot != null or !std.mem.eql(u8, p.attributes, "0")) {
            try diagnostic(a, &diags, "new_gpt_metadata_unsupported", "The host allocator cannot honor an explicit new slot or nonzero attributes.", p.id);
        }
    }
    const stages = try schedule(a, disk, draft, base.operations, filesystems);
    if (stages.maintenance.len != 0) try common.admitMaintenance(a, &diags, disk, draft);
    var valid = true;
    for (diags.items) |d| if (d.severity == .@"error") {
        valid = false;
    };
    if (stages.maintenance.len != 0) try diags.append(a, .{ .code = "maintenance_preflight_required", .severity = .info, .message = "Remaining steps require a verified reboot handoff. Host changes cannot begin until the complete route is prepared." });
    return .{ .version = proto.API_VERSION, .digest = base.digest, .executable = valid and stages.maintenance.len == 0, .offline_validation_required = stages.maintenance.len != 0, .diagnostics = try diags.toOwnedSlice(a), .operations = base.operations, .host_operations = stages.host, .maintenance_operations = stages.maintenance, .rollback_scope = if (stages.maintenance.len != 0) .maintenance_only else .none, .destructive_partitions = try base.destructive_partitions.toOwnedSlice(a), .draft = draft };
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

test "shared plan admission corpus" {
    try proto.plan_validation_cases.run(proto);
}
