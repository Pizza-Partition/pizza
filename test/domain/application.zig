//! Request-routing tests use in-memory boundaries, with no platform imports.
const std = @import("std");
const proto = @import("proto");
const w = proto.wire;
const CURRENT_VERSION = std.fmt.comptimePrint("{d}", .{proto.API_VERSION});
const PREVIOUS_VERSION = std.fmt.comptimePrint("{d}", .{proto.API_VERSION - 1});
const app = @import("../../core/app/service.zig");
const Capabilities = @import("planner.zig").Capabilities;
const DISK_ID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SNAPSHOT_ID = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const SESSION_ID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const Disk = struct {
    capabilities: Capabilities = .{},
    writes: usize = 0,
    queries: usize = 0,
    pub fn query(self: *@This(), _: std.mem.Allocator) !w.InventorySnapshot {
        self.queries += 1;
        return .{ .version = proto.API_VERSION, .snapshot_id = SNAPSHOT_ID, .platform = .linux, .disks = &.{.{ .path = "/dev/test-only", .identity = DISK_ID, .model = "fixture", .capacity = "10485760", .sector_size = 512, .read_only = false, .partition_table = "gpt", .usable_offset = "1048576", .usable_length = "8388608" }} };
    }
    pub fn validLabel(self: *@This(), a: std.mem.Allocator, fs: w.FilesystemKind, label: []const u8) !bool {
        return self.capabilities.validLabel(a, fs, label);
    }
    pub fn canFs(self: *@This(), a: std.mem.Allocator, fs: w.FilesystemKind, op: w.IntentKind, mounted: bool, shrinking: bool) !bool {
        return self.capabilities.canFs(a, fs, op, mounted, shrinking);
    }
    pub fn preflightShrink(_: *@This(), _: std.mem.Allocator, _: w.HostPartition, _: u64) !void {
        return error.UnexpectedPreflight;
    }
    pub fn apply(self: *@This(), _: std.mem.Allocator, _: w.HostDisk, _: w.PlanIntent, _: ?w.DesiredPartition) !void {
        self.writes += 1;
        return error.UnexpectedWrite;
    }
    pub fn failureMessage(_: *@This(), err: anyerror) []const u8 {
        return @errorName(err);
    }
};
const Store = struct {
    record: ?[]const u8 = null,
    writes: usize = 0,
    allocator: ?std.mem.Allocator = null,
    pub fn read(self: *@This(), _: std.mem.Allocator, _: []const u8) !?[]const u8 {
        return self.record;
    }
    pub fn persist(self: *@This(), _: []const u8, bytes: []const u8) !void {
        self.writes += 1;
        const a = self.allocator orelse return error.UnexpectedPersist;
        const record = try a.dupe(u8, bytes);
        if (self.record) |old| a.free(old);
        self.record = record;
    }
    pub fn latest(self: *@This(), a: std.mem.Allocator) !?[]const u8 {
        const bytes = self.record orelse return null;
        const record = try std.json.parseFromSliceLeaky(w.ExecutionSession, a, bytes, .{});
        return record.id;
    }
};
const Sessions = struct {
    worker: @import("../../core/execution/worker.zig") = .{},
    store: Store = .{},
    prompts: usize = 0,
    calls: usize = 0,
    privileged: bool = false,
    response: ?[]const u8 = null,
    pub fn isPrivileged(self: *const @This()) bool {
        return self.privileged;
    }
    pub fn readiness(_: *const @This()) enum { ready, executable_changed, authorization_unavailable } {
        return .ready;
    }
    pub fn elevate(self: *@This(), _: std.mem.Allocator, _: []const u8) !?[]const u8 {
        self.prompts += 1;
        return self.response orelse "{\"version\":" ++ CURRENT_VERSION ++ "}";
    }
    pub fn call(self: *@This(), _: std.mem.Allocator, _: []const u8) !?[]const u8 {
        self.calls += 1;
        return self.response orelse "{\"version\":" ++ CURRENT_VERSION ++ "}";
    }
};
fn fixture() app.service(Disk, Sessions) {
    return .{ .io = std.testing.io, .disk = .{} };
}

const Maintenance = struct {
    calls: usize = 0,
    active: bool = false,
    finished: bool = false,
    armed: bool = false,
    digest: []const u8 = DISK_ID,
    fn port(self: *Maintenance) @import("../../core/boot/session.zig").Controller {
        return .{ .context = self, .prepare = prepare, .reboot = reboot, .complete = complete, .pending = pending, .cancel = cancel };
    }
    fn prepare(ctx: *anyopaque, _: std.mem.Allocator, _: std.Io, _: w.InventorySnapshot, plan: w.ValidatedPlan) !w.MaintenanceSession {
        const self: *Maintenance = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.active = true;
        self.digest = plan.digest;
        return .{ .version = proto.API_VERSION, .id = SESSION_ID, .plan_digest = plan.digest, .phase = .prepared, .message = "fixture prepared" };
    }
    fn reboot(ctx: *anyopaque, _: std.mem.Allocator, _: std.Io, id: []const u8, digest: []const u8) !w.MaintenanceSession {
        const self: *Maintenance = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (!self.active or !std.mem.eql(u8, id, SESSION_ID) or !std.mem.eql(u8, digest, self.digest)) return error.SessionApprovalMismatch;
        self.armed = true;
        return .{ .version = proto.API_VERSION, .id = id, .plan_digest = digest, .phase = .armed, .message = "fixture armed" };
    }
    fn complete(ctx: *anyopaque, _: std.mem.Allocator, _: std.Io, id: ?[]const u8) !w.CompletionReceipt {
        const self: *Maintenance = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (!self.finished) return error.MaintenanceStillOwnsBoot;
        if (id) |value| if (!std.mem.eql(u8, value, SESSION_ID)) return error.SessionApprovalMismatch;
        self.active = false;
        return .{ .version = proto.API_VERSION, .id = SESSION_ID, .plan_digest = self.digest, .program_digest = DISK_ID, .disk_identity = DISK_ID, .image_digest = DISK_ID, .outcome = .completed, .message = "fixture complete" };
    }
    fn pending(ctx: *anyopaque) !bool {
        const self: *Maintenance = @ptrCast(@alignCast(ctx));
        return self.active;
    }
    fn cancel(ctx: *anyopaque, _: std.mem.Allocator, _: std.Io, id: []const u8, approved: ?[]const u8) !?w.MaintenanceSession {
        const self: *Maintenance = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, id, SESSION_ID)) return null;
        if (!std.mem.eql(u8, approved orelse return error.MissingApproval, self.digest)) return error.SessionApprovalMismatch;
        if (self.armed) return error.InvalidSessionTransition;
        self.active = false;
        return .{ .version = proto.API_VERSION, .id = id, .plan_digest = self.digest, .phase = .failed, .message = "Preparation cancelled" };
    }
};

test "preparation cancellation requires approval, releases the worker and refuses armed sessions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service = fixture();
    service.sessions.privileged = true;
    var maintenance: Maintenance = .{ .active = true };
    service.maintenance = maintenance.port();
    var request: w.PrivilegedRequest = .{ .version = proto.API_VERSION, .action = .cancel, .session_id = SESSION_ID };
    try std.testing.expectError(error.MissingApproval, service.dispatch(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }), .privileged));
    try std.testing.expect(maintenance.active and !service.sessions.worker.busy());
    request.approved_digest = DISK_ID;
    _ = try service.dispatch(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }), .privileged);
    try std.testing.expect(!maintenance.active and !service.sessions.worker.busy());
    maintenance.active = true;
    maintenance.armed = true;
    try std.testing.expectError(error.InvalidSessionTransition, service.dispatch(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }), .privileged));
    try std.testing.expect(maintenance.active and !service.sessions.worker.busy());
    try std.testing.expectEqual(0, service.disk.writes);
}

test "maintenance routing binds approval, excludes host writes and waits for completion" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service = fixture();
    service.sessions.privileged = true;
    service.disk.capabilities.available = false;
    var maintenance: Maintenance = .{};
    service.maintenance = maintenance.port();
    const editor = @import("../../core/planning/editor.zig");
    const snapshot = try service.disk.query(a);
    const opened = try std.json.parseFromSliceLeaky(editor.Result, a, try service.plan(a, try std.json.Stringify.valueAlloc(a, editor.Request{ .version = proto.API_VERSION, .snapshot_id = snapshot.snapshot_id, .disk_identity = DISK_ID }, .{ .emit_null_optional_fields = false })), .{});
    const response = try service.plan(a, try std.json.Stringify.valueAlloc(a, editor.Request{ .version = proto.API_VERSION, .snapshot_id = snapshot.snapshot_id, .disk_identity = DISK_ID, .command = .{ .kind = .add_left, .partition_id = opened.regions[0].id, .filesystem = .ext4 }, .review = true }, .{ .emit_null_optional_fields = false }));
    const generated = try std.json.parseFromSliceLeaky(editor.Result, a, response, .{});
    const draft = generated.draft;
    const plan = generated.validated.?;
    try std.testing.expect(plan.offline_validation_required);
    var request: w.PrivilegedRequest = .{ .version = proto.API_VERSION, .action = .prepare, .draft = draft, .approved_digest = DISK_ID };
    try std.testing.expectError(error.PlanApprovalChanged, service.dispatch(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }), .privileged));
    try std.testing.expectEqual(0, maintenance.calls);
    request.approved_digest = plan.digest;
    const prepared = try std.json.parseFromSliceLeaky(w.MaintenanceSession, a, try service.dispatch(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }), .privileged), .{});
    try std.testing.expectEqual(.prepared, prepared.phase);
    request.action = .execute;
    try std.testing.expectError(error.MaintenanceSessionInProgress, service.dispatch(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }), .privileged));
    try std.testing.expectEqual(0, service.disk.writes);
    request = .{ .version = proto.API_VERSION, .action = .reboot, .session_id = SESSION_ID, .approved_digest = DISK_ID };
    try std.testing.expectError(error.SessionApprovalMismatch, service.dispatch(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }), .privileged));
    request.approved_digest = plan.digest;
    const armed = try std.json.parseFromSliceLeaky(w.MaintenanceSession, a, try service.dispatch(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }), .privileged), .{});
    try std.testing.expectEqual(.armed, armed.phase);
    request.action = .complete;
    try std.testing.expectError(error.MaintenanceStillOwnsBoot, service.dispatch(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }), .privileged));
    maintenance.finished = true;
    const receipt = try std.json.parseFromSliceLeaky(w.CompletionReceipt, a, try service.dispatch(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }), .privileged), .{});
    try std.testing.expectEqual(.completed, receipt.outcome);
    try std.testing.expect(!maintenance.active and !service.sessions.worker.busy());
}

test "local status and cancel reuse authorization; explicit elevation prompts once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service = fixture();
    _ = try service.dispatch(a, "{\"version\":" ++ CURRENT_VERSION ++ ",\"action\":\"status\"}", .local);
    _ = try service.dispatch(a, "{\"version\":" ++ CURRENT_VERSION ++ ",\"action\":\"cancel\",\"session_id\":\"" ++ SESSION_ID ++ "\"}", .local);
    try std.testing.expectEqual(@as(usize, 2), service.sessions.calls);
    try std.testing.expectEqual(@as(usize, 0), service.sessions.prompts);
    _ = try service.dispatch(a, "{\"version\":" ++ CURRENT_VERSION ++ ",\"action\":\"inventory\",\"elevated\":true}", .local);
    try std.testing.expectEqual(@as(usize, 1), service.sessions.prompts);
    _ = try service.dispatch(a, "{\"version\":" ++ CURRENT_VERSION ++ ",\"action\":\"inventory\"}", .local);
    try std.testing.expectEqual(@as(usize, 1), service.sessions.prompts);
}
test "invalid requests and unauthenticated execution never reach disk writes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service = fixture();
    try std.testing.expectError(error.UnsupportedProtocolVersion, service.dispatch(a, "{\"version\":" ++ PREVIOUS_VERSION ++ ",\"action\":\"execute\"}", .local));
    try std.testing.expectEqual(@as(usize, 0), service.sessions.prompts);
    try std.testing.expectError(error.RootRequired, service.dispatch(a, "{\"version\":" ++ CURRENT_VERSION ++ ",\"action\":\"execute\"}", .privileged));
    try std.testing.expectEqual(@as(usize, 0), service.disk.writes);
    try std.testing.expectEqual(@as(usize, 0), service.sessions.store.writes);
}
test "lost worker status is reconciled without rewriting durable records" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service = fixture();
    service.sessions.privileged = true;
    service.sessions.store.record = try std.json.Stringify.valueAlloc(a, w.ExecutionSession{ .version = proto.API_VERSION, .id = SESSION_ID, .plan_digest = DISK_ID, .status = .running, .completed = 1, .total = 2, .message = "fixture" }, .{ .emit_null_optional_fields = false });
    const response = try service.dispatch(a, "{\"version\":" ++ CURRENT_VERSION ++ ",\"action\":\"status\",\"approved_digest\":\"" ++ DISK_ID ++ "\"}", .privileged);
    const status = try std.json.parseFromSliceLeaky(w.ExecutionSession, a, response, .{});
    try std.testing.expectEqual(.needs_recheck, status.status);
    try std.testing.expectEqual(@as(u32, 1), status.completed);
    try std.testing.expect(status.actual != null);
    try std.testing.expectEqual(@as(usize, 0), service.sessions.store.writes);
    try std.testing.expectEqual(@as(usize, 0), service.disk.writes);
    try std.testing.expectError(error.SessionApprovalMismatch, service.dispatch(a, "{\"version\":" ++ CURRENT_VERSION ++ ",\"action\":\"status\",\"approved_digest\":\"wrong\"}", .privileged));
}
test "metadata reports the supplied filesystem capabilities" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service = fixture();
    const available = try std.json.parseFromSliceLeaky(std.json.Value, a, try service.metadata(a), .{});
    try std.testing.expectEqual(std.meta.tags(w.FilesystemKind).len, available.object.get("formats").?.array.items.len);
    service.disk.capabilities.available = false;
    const result = try std.json.parseFromSliceLeaky(std.json.Value, a, try service.metadata(a), .{});
    try std.testing.expectEqual(@as(usize, 0), result.object.get("formats").?.array.items.len);
}

test "changed approval fails before persistence or execution and releases the lease" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service = fixture();
    service.sessions.privileged = true;
    const draft: w.PlanDraft = .{ .version = proto.API_VERSION, .snapshot_id = SNAPSHOT_ID, .disk_identity = DISK_ID };
    const request: w.PrivilegedRequest = .{ .version = proto.API_VERSION, .action = .execute, .draft = draft, .approved_digest = DISK_ID };
    try std.testing.expectError(error.PlanApprovalChanged, service.dispatch(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }), .privileged));
    try std.testing.expectEqual(@as(usize, 0), service.sessions.store.writes);
    try std.testing.expectEqual(@as(usize, 0), service.disk.writes);
    try std.testing.expect(!service.sessions.worker.busy());
    try std.testing.expect((try service.sessions.worker.currentId(a)) == null);
}

test "approved no-change plan completes through the injected worker and record store" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service = fixture();
    service.sessions.privileged = true;
    service.sessions.store.allocator = std.testing.allocator;
    defer {
        while (service.sessions.worker.busy()) std.Thread.yield() catch {};
        if (service.sessions.store.record) |record| std.testing.allocator.free(record);
    }
    const draft: w.PlanDraft = .{ .version = proto.API_VERSION, .snapshot_id = SNAPSHOT_ID, .disk_identity = DISK_ID };
    const plan = try @import("../../core/planning/planner.zig").validate(a, try service.disk.query(a), draft, &service.disk);
    try std.testing.expect(plan.executable);
    const request: w.PrivilegedRequest = .{ .version = proto.API_VERSION, .action = .execute, .draft = draft, .approved_digest = plan.digest };
    const queued = try std.json.parseFromSliceLeaky(w.ExecutionSession, a, try service.dispatch(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }), .privileged), .{});
    try std.testing.expectEqual(.prepared, queued.status);
    while (service.sessions.worker.busy()) std.Thread.yield() catch {};
    const query: w.PrivilegedRequest = .{ .version = proto.API_VERSION, .action = .status, .session_id = queued.id, .approved_digest = plan.digest };
    const completed = try std.json.parseFromSliceLeaky(w.ExecutionSession, a, try service.dispatch(a, try std.json.Stringify.valueAlloc(a, query, .{ .emit_null_optional_fields = false }), .privileged), .{});
    try std.testing.expectEqual(.succeeded, completed.status);
    try std.testing.expectEqualStrings(queued.id, completed.id);
    try std.testing.expect(completed.actual != null);
    try std.testing.expectEqual(@as(u32, 0), completed.completed);
    try std.testing.expectEqual(@as(usize, 0), service.disk.writes);
}

test "plan endpoint derives executable approval without trusting client intents or stale inventory" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const editor = @import("../../core/planning/editor.zig");
    var service = fixture();
    const initial: editor.Request = .{ .version = proto.API_VERSION, .snapshot_id = SNAPSHOT_ID, .disk_identity = DISK_ID };
    const initial_response = try service.plan(a, try std.json.Stringify.valueAlloc(a, initial, .{ .emit_null_optional_fields = false }));
    const opened = try std.json.parseFromSliceLeaky(editor.Result, a, initial_response, .{});
    try std.testing.expectEqual(0, opened.draft.intents.len);
    var request = initial;
    request.command = .{ .kind = .add_left, .partition_id = opened.regions[0].id, .filesystem = .ntfs };
    request.review = true;
    const result = try std.json.parseFromSliceLeaky(editor.Result, a, try service.plan(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false })), .{});
    try std.testing.expectEqual(.create, result.draft.intents[0].kind);
    try std.testing.expect(result.validated.?.executable);
    try std.testing.expectEqualStrings(result.validated.?.digest, (try @import("../../core/planning/planner.zig").validate(a, try service.disk.query(a), result.draft, &service.disk)).digest);
    try std.testing.expectEqual(0, service.disk.writes);
    try std.testing.expectEqual(0, service.sessions.prompts);
    request.snapshot_id = DISK_ID;
    try std.testing.expectError(error.StaleInventory, service.plan(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false })));
    try std.testing.expectError(error.UnknownField, service.plan(a, "{\"version\":" ++ CURRENT_VERSION ++ ",\"snapshot_id\":\"" ++ SNAPSHOT_ID ++ "\",\"disk_identity\":\"" ++ DISK_ID ++ "\",\"intents\":[]}"));
    const too_large = try a.alloc(u8, app.MAX_BYTES + 1);
    try std.testing.expectError(error.RequestTooLarge, service.plan(std.testing.failing_allocator, too_large));
    try std.testing.expectEqual(0, service.disk.writes);
}

test "plan endpoint obtains elevated inventory through the authorization channel" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const editor = @import("../../core/planning/editor.zig");
    var service = fixture();
    var authorized = try service.disk.query(a);
    authorized.snapshot_id = DISK_ID;
    service.sessions.response = try std.json.Stringify.valueAlloc(a, authorized, .{ .emit_null_optional_fields = false });
    service.disk.queries = 0;
    const request: editor.Request = .{ .version = proto.API_VERSION, .snapshot_id = DISK_ID, .disk_identity = DISK_ID, .elevated = true, .review = true };
    const result = try std.json.parseFromSliceLeaky(editor.Result, a, try service.plan(a, try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false })), .{});
    try std.testing.expectEqualStrings(DISK_ID, result.draft.snapshot_id);
    try std.testing.expectEqual(1, service.sessions.prompts);
    try std.testing.expectEqual(0, service.disk.queries);
    try std.testing.expectEqual(0, service.disk.writes);
    try std.testing.expect(result.validated.?.executable);
}

test "status refuses a durable record belonging to another session" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service = fixture();
    service.sessions.privileged = true;
    service.sessions.store.record = try std.json.Stringify.valueAlloc(a, w.ExecutionSession{ .version = proto.API_VERSION, .id = SESSION_ID, .plan_digest = DISK_ID, .status = .succeeded, .completed = 0, .total = 0, .message = "fixture" }, .{ .emit_null_optional_fields = false });
    try std.testing.expectError(error.SessionIdentityMismatch, service.dispatch(a, try std.json.Stringify.valueAlloc(a, w.PrivilegedRequest{ .version = proto.API_VERSION, .action = .status, .session_id = DISK_ID }, .{ .emit_null_optional_fields = false }), .privileged));
}
