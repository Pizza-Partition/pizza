//! Queue approved plans, validate again before writing, and reconcile durable progress.
const json = @import("../json.zig").json;
const std = @import("std");
const proto = @import("proto");
const wire = proto.wire;

pub fn status(app: anytype, a: std.mem.Allocator, id: []const u8) !wire.ExecutionSession {
    const out = try app.sessions.store.read(a, id) orelse return error.SessionNotFound;
    var result = try std.json.parseFromSliceLeaky(wire.ExecutionSession, a, out, .{});
    if (result.version != proto.API_VERSION) return error.UnsupportedProtocolVersion;
    if (!std.mem.eql(u8, result.id, id)) return error.SessionIdentityMismatch;
    if (result.status == .running or result.status == .prepared) {
        if (!app.sessions.worker.executionActive(id)) {
            result.status = .needs_recheck;
            result.message = "The execution service stopped. Inspect actual disk state; completed steps will not be replayed.";
            result.actual = try app.disk.query(a);
            // A worker can be publishing its prepared record before starting its
            // task. Only inspect here; never race its durable state with a write.
        } else result.cancel_requested = app.sessions.worker.executionCancelled(id);
    }
    return result;
}

const Task = struct {
    session: wire.ExecutionSession,
    request: wire.PrivilegedRequest,
};

pub fn start(app: anytype, a: std.mem.Allocator, r: wire.PrivilegedRequest) !wire.ExecutionSession {
    if (!app.sessions.worker.writeLock()) return error.ExecutionInProgress;
    var handed_off = false;
    defer if (!handed_off) app.sessions.worker.writeUnlock();
    // Check under the same lock as prepare: otherwise a competing preparation
    // could install a durable boot handoff between this check and execution.
    const maintenance = app.maintenance;
    if (try maintenance.pending(maintenance.context)) return error.MaintenanceSessionInProgress;
    const draft = r.draft orelse return error.MissingDraft;
    const approval = try @import("approval.zig").check(app, a, r);
    const snapshot = approval.snapshot;
    const validated = approval.validated;
    if (!validated.executable) return error.PlanNotExecutable;
    try preflight(app, a, snapshot, draft, validated);
    var random: [32]u8 = undefined;
    app.io.random(&random);
    var run: wire.ExecutionSession = .{ .version = proto.API_VERSION, .id = try a.dupe(u8, &std.fmt.bytesToHex(random, .lower)), .plan_digest = validated.digest, .status = .prepared, .completed = 0, .total = @intCast(validated.host_operations.len), .message = "Approved host execution queued. Completed host steps have no unified Undo." };
    try app.sessions.store.persist(run.id, try json(a, run));
    const task = try json(a, Task{ .session = run, .request = r });
    app.sessions.worker.startExecution(app.io, run.id, task, app, taskRunner(@TypeOf(app.*)).run) catch |err| {
        std.log.err("Execution worker could not start: {t}", .{err});
        run.status = .failed;
        run.message = "Execution worker could not start; no disk operation was started.";
        try app.sessions.store.persist(run.id, try json(a, run));
        return run;
    };
    handed_off = true;
    return run;
}

fn createBackendType(comptime App: type) type {
    return struct {
        app: *App,
        a: std.mem.Allocator,
        id: []const u8,
        pub fn query(self: *@This()) !wire.InventorySnapshot {
            return self.app.disk.query(self.a);
        }
        pub fn persist(self: *@This(), s: wire.ExecutionSession) !void {
            return self.app.sessions.store.persist(s.id, try json(self.a, s));
        }
        pub fn cancelled(self: *@This()) bool {
            return self.app.sessions.worker.executionCancelled(self.id);
        }
        pub fn apply(self: *@This(), d: wire.HostDisk, op: wire.PlanIntent, p: ?wire.DesiredPartition) !void {
            return self.app.disk.apply(self.a, d, op, p);
        }
        pub fn failureMessage(self: *@This(), err: anyerror) []const u8 {
            return self.app.disk.failureMessage(err);
        }
    };
}

fn preflight(app: anytype, a: std.mem.Allocator, snapshot: wire.InventorySnapshot, draft: wire.PlanDraft, validated: wire.ValidatedPlan) !void {
    const disk = try @import("../execution/state.zig").disk(snapshot, draft.disk_identity);
    for (validated.host_operations) |op| {
        if (op.kind != .resize) continue;
        const old = for (disk.partitions) |p| {
            if (std.mem.eql(u8, p.id, op.partition_id)) break p;
        } else return error.MissingOperationTarget;
        const desired = for (draft.layout) |p| {
            if (std.mem.eql(u8, p.id, op.partition_id)) break p;
        } else return error.MissingOperationTarget;
        const size = try proto.byteCount(desired.length);
        if (size >= try proto.byteCount(old.length)) continue;
        try app.disk.preflightShrink(a, old, size);
    }
}

fn runTask(a: std.mem.Allocator, task: *Task, backend: anytype) !void {
    const app = backend.app;
    const draft = task.request.draft orelse return error.MissingDraft;
    const snapshot = try backend.query();
    const validated = try @import("../planning/planner.zig").validate(a, snapshot, draft, &app.disk);
    if (!validated.executable or !std.mem.eql(u8, validated.digest, task.session.plan_digest)) {
        task.session.status = .failed;
        task.session.message = "Disk state or plan feasibility changed before execution; no operation was started.";
        task.session.actual = snapshot;
        try backend.persist(task.session);
        return;
    }
    preflight(app, a, snapshot, draft, validated) catch |err| {
        task.session.status = .failed;
        task.session.message = try a.dupe(u8, if (err == error.HostPreflightFailed) app.disk.failureMessage(err) else @errorName(err));
        task.session.actual = snapshot;
        try backend.persist(task.session);
        return;
    };
    try @import("../execution/runner.zig").run(a, draft, validated, snapshot, &task.session, backend);
}

fn taskRunner(comptime App: type) type {
    return struct {
        fn run(context: ?*anyopaque, bytes: []const u8) void {
            const app: *App = @ptrCast(@alignCast(context.?));
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var task = std.json.parseFromSliceLeaky(Task, a, bytes, .{}) catch |err| {
                std.log.err("Cannot decode queued execution task: {t}; persisted session requires recheck", .{err});
                return;
            };
            var backend: createBackendType(App) = .{ .a = a, .app = app, .id = task.session.id };
            runTask(a, &task, &backend) catch |err| {
                @import("../execution/runner.zig").stop(a, &task.session, &backend, err) catch {
                    // A failed durable write must never be reported as success. The last
                    // running record becomes needs_recheck when the service is reconnected.
                    std.log.err("Session {s}: cannot persist failure {s}", .{ task.session.id, @errorName(err) });
                };
            };
        }
    };
}
