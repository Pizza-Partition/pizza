const std = @import("std");
const proto = @import("proto");
const w = @import("proto").wire;
const MIB = 1024 * 1024;
fn fixture() struct { disk: w.HostDisk, inventory: w.InventorySnapshot } {
    return .{ .disk = .{ .path = "/dev/disposable", .identity = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .capacity = "10485760", .sector_size = 512, .model = "fixture", .read_only = false, .partition_table = "gpt", .usable_offset = "1048576", .usable_length = "8388608", .partitions = &.{.{ .id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .offset = "1048576", .length = "6291456", .name = "", .filesystem = .ext4, .encryption = .none, .path = "/dev/disposable1", .capabilities = &.{.{ .operation = .resize, .backend = .host, .support = .available, .reason = "fixture", .grow = true, .shrink = true }} }} }, .inventory = .{ .version = proto.API_VERSION, .snapshot_id = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .platform = .linux } };
}
test "host scheduler shrinks before creating in the released range" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fixture();
    f.inventory.disks = &.{f.disk};
    const id = f.disk.partitions[0].id;
    const new_id = try @import("../../core/planning/identity.zig").partition(a, f.disk.identity.?, "11111111111111111111111111111111");
    const draft: w.PlanDraft = .{ .version = proto.API_VERSION, .snapshot_id = f.inventory.snapshot_id, .disk_identity = f.disk.identity.?, .intents = &.{ .{ .kind = .create, .partition_id = new_id, .offset = "5242880", .length = "2097152", .filesystem = .ext4 }, .{ .kind = .resize, .partition_id = id, .length = "4194304" } }, .layout = &.{ .{ .id = id, .offset = "1048576", .length = "4194304", .name = f.disk.partitions[0].name, .filesystem = .ext4 }, .{ .id = new_id, .offset = "5242880", .length = "2097152", .name = "New", .filesystem = .ext4, .retain_data = false, .type_guid = "af3dc60f838472478e793d69d8477de4", .partition_uuid = "11111111111111111111111111111111" } } };
    const result = try @import("../../core/planning/planner.zig").validate(a, f.inventory, draft, Capabilities{});
    try std.testing.expect(result.executable);
    try std.testing.expectEqual(@as(usize, 2), result.host_operations.len);
    try std.testing.expectEqual(.resize, result.host_operations[0].kind);
    try std.testing.expectEqual(.create, result.host_operations[1].kind);

    // The same reviewed plan must become non-executable when the supplied
    // platform cannot perform its filesystem operations.
    const unavailable = try @import("../../core/planning/planner.zig").validate(a, f.inventory, draft, Capabilities{ .available = false });
    try std.testing.expect(!unavailable.executable);
    try std.testing.expectEqual(@as(usize, 0), unavailable.host_operations.len);
    try std.testing.expectEqual(@as(usize, 2), unavailable.maintenance_operations.len);
    try std.testing.expectEqualStrings(result.digest, unavailable.digest);
    const invalid_label = try @import("../../core/planning/planner.zig").validate(a, f.inventory, draft, Capabilities{ .label_valid = false });
    try std.testing.expect(!invalid_label.executable);
    for (invalid_label.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "filesystem_label_rejected")) return;
    }
    return error.MissingLabelDiagnostic;
}
test "stale baseline and encrypted volumes cannot execute" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fixture();
    var partitions = try a.dupe(w.HostPartition, f.disk.partitions);
    partitions[0].encryption = .encrypted;
    f.disk.partitions = partitions;
    f.inventory.disks = &.{f.disk};
    const draft: w.PlanDraft = .{ .version = proto.API_VERSION, .snapshot_id = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .disk_identity = f.disk.identity.?, .intents = &.{.{ .kind = .delete, .partition_id = partitions[0].id }} };
    const result = try @import("../../core/planning/planner.zig").validate(a, f.inventory, draft, Capabilities{});
    try std.testing.expect(!result.executable);
    var stale = false;
    var encrypted = false;
    for (result.diagnostics) |d| {
        stale = stale or std.mem.eql(u8, d.code, "stale_inventory");
        encrypted = encrypted or std.mem.eql(u8, d.code, "protected_partition");
    }
    try std.testing.expect(stale and encrypted);
}

pub const Capabilities = struct {
    available: bool = true,
    label_valid: bool = true,
    pub fn validLabel(self: Capabilities, _: std.mem.Allocator, _: w.FilesystemKind, _: []const u8) !bool {
        return self.label_valid;
    }
    pub fn canFs(self: Capabilities, _: std.mem.Allocator, _: w.FilesystemKind, _: w.IntentKind, _: bool, _: bool) !bool {
        return self.available;
    }
};
