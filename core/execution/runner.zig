//! Host execution stops at step boundaries. Successful steps are never replayed.
const std = @import("std");
const proto = @import("proto");
const wire = @import("proto").wire;
const state = @import("state.zig");

pub fn run(a: std.mem.Allocator, draft: wire.PlanDraft, plan: wire.ValidatedPlan, initial: wire.InventorySnapshot, session: *wire.ExecutionSession, backend: anytype) !void {
    session.status = .running;
    try backend.persist(session.*);
    var expected = try state.disk(initial, draft.disk_identity);
    for (plan.host_operations) |op| {
        if (try cancel(session, backend)) return;
        const actual = backend.query() catch |err| return stop(a, session, backend, err);
        const disk = state.disk(actual, draft.disk_identity) catch |err| return stop(a, session, backend, err);
        state.unchanged(expected, disk) catch |err| return stop(a, session, backend, err);
        const desired: ?wire.DesiredPartition = for (draft.layout) |p| {
            if (std.mem.eql(u8, p.id, op.partition_id)) break p;
        } else null;
        session.message = try a.print("Starting {s} for {s}; interruption requires inspecting actual disk state.", .{ @tagName(op.kind), op.partition_id });
        try backend.persist(session.*);
        if (try cancel(session, backend)) return;
        backend.apply(disk, op, desired) catch |err| {
            session.status = if (session.completed != 0) .partial else .needs_recheck;
            session.message = try a.dupe(u8, backend.failureMessage(err));
            session.actual = backend.query() catch null;
            session.cancel_requested = backend.cancelled();
            try backend.persist(session.*);
            return;
        };
        // Always finish verification and durable accounting of a started write,
        // even if a cancellation arrived while the library was working.
        const observed = backend.query() catch |err| return stop(a, session, backend, err);
        const after = state.disk(observed, draft.disk_identity) catch |err| return stop(a, session, backend, err);
        state.verify(disk, after, op, desired) catch |err| return stop(a, session, backend, err);
        expected = after;
        session.completed += 1;
        session.actual = observed;
        session.cancel_requested = backend.cancelled();
        try backend.persist(session.*);
    }
    session.actual = backend.query() catch |err| return stop(a, session, backend, err);
    session.status = .succeeded;
    session.message = "Host steps completed. These changes have no unified Undo.";
    session.cancel_requested = backend.cancelled();
    try backend.persist(session.*);
}
fn cancel(session: *wire.ExecutionSession, backend: anytype) !bool {
    if (!backend.cancelled()) return false;
    session.status = .cancelled;
    session.cancel_requested = true;
    session.message = "Stopped before the next step. Completed host changes remain on disk and have no unified Undo.";
    session.actual = backend.query() catch null;
    try backend.persist(session.*);
    return true;
}
pub fn stop(a: std.mem.Allocator, session: *wire.ExecutionSession, backend: anytype, err: anyerror) !void {
    session.status = if (session.completed != 0) .partial else .needs_recheck;
    session.message = try a.print("{s}: stopped before another operation. Inspect actual disk state; changes may already be present.", .{@errorName(err)});
    session.actual = backend.query() catch null;
    session.cancel_requested = backend.cancelled();
    try backend.persist(session.*);
}

const Mock = struct {
    parts: [2]wire.HostPartition = .{
        .{ .id = "first", .offset = "1048576", .length = "2097152", .name = "First", .filesystem = .ext4, .encryption = .none },
        .{ .id = "second", .offset = "4194304", .length = "2097152", .name = "Second", .filesystem = .ext4, .encryption = .none },
    },
    cancel_flag: bool = false,
    cancel_on_apply: bool = false,
    fail_after_write: bool = false,
    wrong_geometry: bool = false,
    foreign_change: bool = false,
    sync_fail_after_write: bool = false,
    writes: usize = 0,
    records: usize = 0,

    pub fn apply(self: *Mock, _: wire.HostDisk, op: wire.PlanIntent, desired: ?wire.DesiredPartition) !void {
        self.writes += 1;
        for (&self.parts) |*p| if (std.mem.eql(u8, p.id, op.partition_id)) {
            p.name = desired.?.name;
            if (self.wrong_geometry) p.length = "512";
        };
        if (self.cancel_on_apply) self.cancel_flag = true;
        if (self.fail_after_write) return error.LibraryFailedAfterWrite;
    }
    pub fn cancelled(self: *Mock) bool {
        return self.cancel_flag;
    }
    pub fn persist(self: *Mock, _: wire.ExecutionSession) !void {
        if (self.sync_fail_after_write and self.writes != 0) return error.SessionSyncFailed;
        self.records += 1;
    }
    pub fn failureMessage(_: *Mock, err: anyerror) []const u8 {
        return @errorName(err);
    }
};
const FixtureBackend = struct {
    mock: Mock = .{},
    arena: std.heap.ArenaAllocator,
    pub fn query(self: *@This()) !wire.InventorySnapshot {
        const a = self.arena.allocator();
        if (self.mock.foreign_change) self.mock.parts[1].name = "Foreign change";
        // A real inventory snapshot does not alias mutable simulated media.
        return .{ .version = proto.API_VERSION, .snapshot_id = "fixture", .platform = .linux, .disks = try a.dupe(wire.HostDisk, &.{.{ .path = "/dev/fixture", .identity = "disk", .capacity = "16777216", .sector_size = 512, .model = "fixture", .read_only = false, .partitions = try a.dupe(wire.HostPartition, &self.mock.parts) }}) };
    }
    pub fn apply(self: *@This(), d: wire.HostDisk, op: wire.PlanIntent, p: ?wire.DesiredPartition) !void {
        return self.mock.apply(d, op, p);
    }
    pub fn cancelled(self: *@This()) bool {
        return self.mock.cancelled();
    }
    pub fn persist(self: *@This(), s: wire.ExecutionSession) !void {
        return self.mock.persist(s);
    }
    pub fn failureMessage(self: *@This(), err: anyerror) []const u8 {
        return self.mock.failureMessage(err);
    }
};
fn exercise(mock: Mock) !struct { session: wire.ExecutionSession, writes: usize } {
    var backend: FixtureBackend = .{ .mock = mock, .arena = .init(std.testing.allocator) };
    defer backend.arena.deinit();
    backend.mock.foreign_change = false;
    const initial = try backend.query();
    backend.mock.foreign_change = mock.foreign_change;
    const ops: []const wire.PlanIntent = &.{ .{ .kind = .label, .partition_id = "first" }, .{ .kind = .label, .partition_id = "second" } };
    const draft: wire.PlanDraft = .{ .version = proto.API_VERSION, .snapshot_id = "fixture", .disk_identity = "disk", .intents = ops, .layout = &.{ .{ .id = "first", .offset = "1048576", .length = "2097152", .name = "Renamed first", .filesystem = .ext4 }, .{ .id = "second", .offset = "4194304", .length = "2097152", .name = "Renamed second", .filesystem = .ext4 } } };
    const plan: wire.ValidatedPlan = .{ .version = proto.API_VERSION, .draft = draft, .digest = "digest", .executable = true, .offline_validation_required = false, .host_operations = ops };
    var session: wire.ExecutionSession = .{ .version = proto.API_VERSION, .id = "session", .plan_digest = "digest", .status = .prepared, .completed = 0, .total = 2, .message = "prepared" };
    try run(backend.arena.allocator(), draft, plan, initial, &session, &backend);
    session.actual = null;
    session.message = "";
    return .{ .session = session, .writes = backend.mock.writes };
}
test "cancellation before execution performs no write" {
    const r = try exercise(.{ .cancel_flag = true });
    try std.testing.expectEqual(.cancelled, r.session.status);
    try std.testing.expectEqual(@as(usize, 0), r.writes);
}
test "cancellation during a write accounts for it before stopping subsequent steps" {
    const r = try exercise(.{ .cancel_on_apply = true });
    try std.testing.expectEqual(.cancelled, r.session.status);
    try std.testing.expectEqual(@as(u32, 1), r.session.completed);
    try std.testing.expectEqual(@as(usize, 1), r.writes);
}
test "a failed library call may already have modified the disk and is never retried" {
    const r = try exercise(.{ .fail_after_write = true });
    try std.testing.expectEqual(.needs_recheck, r.session.status);
    try std.testing.expectEqual(@as(u32, 0), r.session.completed);
    try std.testing.expectEqual(@as(usize, 1), r.writes);
}
test "unexpected postconditions and external layout changes stop later steps" {
    const r = try exercise(.{ .wrong_geometry = true });
    try std.testing.expectEqual(.needs_recheck, r.session.status);
    try std.testing.expectEqual(@as(usize, 1), r.writes);
    const changed = try exercise(.{ .foreign_change = true });
    try std.testing.expectEqual(.needs_recheck, changed.session.status);
    try std.testing.expectEqual(@as(usize, 0), changed.writes);
}
test "durable accounting failure stops the execution loop" {
    try std.testing.expectError(error.SessionSyncFailed, exercise(.{ .sync_fail_after_write = true }));
}
test "successful host steps finish with no unified rollback" {
    const r = try exercise(.{});
    try std.testing.expectEqual(.succeeded, r.session.status);
    try std.testing.expectEqual(@as(u32, 2), r.session.completed);
    try std.testing.expectEqual(.none, r.session.rollback_scope);
}
