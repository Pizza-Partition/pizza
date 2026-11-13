//! Application requests and authorization routing; no WebUI or operating-system APIs.
const std = @import("std");
const proto = @import("proto");
const wire = proto.wire;
const coordinator = @import("coordinator.zig");
pub const MAX_BYTES = 4 * 1024 * 1024;
pub const Access = enum { local, privileged };

/// Disk supplies discovery, validation capabilities and writes. Sessions supplies
/// authorization, an execution worker and durable records. Both are owned here.
pub fn service(comptime Disk: type, comptime Sessions: type) type {
    return struct {
        const Self = @This();
        io: std.Io,
        disk: Disk,
        sessions: Sessions = .{},
        maintenance: ?@import("../boot/ports.zig").Controller = null,

        /// UI and CLI share this read-only editor endpoint. Elevated discovery
        /// uses the existing privileged inventory channel, never client data.
        pub fn plan(self: *Self, a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
            const editor = @import("../planning/editor.zig");
            if (bytes.len > MAX_BYTES) return error.RequestTooLarge;
            const request = try std.json.parseFromSliceLeaky(editor.Request, a, bytes, .{});
            if (request.version != proto.API_VERSION) return error.UnsupportedProtocolVersion;
            const snapshot = if (request.elevated and !self.sessions.isPrivileged()) blk: {
                const message = try std.json.Stringify.valueAlloc(a, wire.PrivilegedRequest{ .version = proto.API_VERSION, .action = .inventory, .elevated = true }, .{ .emit_null_optional_fields = false });
                const response = try self.dispatch(a, message, .local);
                const envelope = try std.json.parseFromSliceLeaky(std.json.Value, a, response, .{});
                if (envelope == .object and envelope.object.get("error") != null) return response;
                break :blk try std.json.parseFromSliceLeaky(wire.InventorySnapshot, a, response, .{});
            } else try self.disk.query(a);
            var result = try editor.edit(a, self.io, snapshot, request);
            if (request.review) result.validated = try @import("../planning/planner.zig").validate(a, snapshot, result.draft, &self.disk);
            return std.json.Stringify.valueAlloc(a, result, .{ .emit_null_optional_fields = false });
        }

        pub fn metadata(self: *Self, a: std.mem.Allocator) ![]const u8 {
            const readiness = self.sessions.readiness();
            const issue: ?[]const u8 = switch (readiness) {
                .ready => null,
                .executable_changed => "This running build was moved or replaced. Restart Pizza before authorizing access.",
                .authorization_unavailable => "Administrator authorization is unavailable. Check the operating system's authorization service.",
            };
            var formats: std.ArrayList([]const u8) = .empty;
            for (std.meta.tags(wire.FilesystemKind)) |fs| {
                if (try self.disk.canFs(a, fs, .format, false, false)) try formats.append(a, @tagName(fs));
            }
            return std.json.Stringify.valueAlloc(a, .{ .version = proto.API_VERSION, .protocol = proto.API_VERSION, .writes_enabled = readiness == .ready, .maintenance_available = self.maintenance != null, .execution_issue = issue, .formats = formats.items, .capabilities = .{ "inventory", "plan", "validate", "execute", "status", "cancel", "discover" } }, .{ .emit_null_optional_fields = false });
        }

        pub fn dispatch(self: *Self, a: std.mem.Allocator, bytes: []const u8, access: Access) ![]const u8 {
            const r = try parseRequest(a, bytes);
            if (r.elevated and access == .local)
                return try self.sessions.elevate(a, bytes) orelse error.PrivilegedServiceUnavailable;
            switch (r.action) {
                .inventory => return std.json.Stringify.valueAlloc(a, try self.disk.query(a), .{ .emit_null_optional_fields = false }),
                .validate => return std.json.Stringify.valueAlloc(a, try @import("../planning/planner.zig").validate(a, try self.disk.query(a), r.draft orelse return error.MissingDraft, &self.disk), .{ .emit_null_optional_fields = false }),
                else => {},
            }
            if (access == .local) {
                // Polling and cancellation reuse authorization instead of prompting.
                return (if (r.action == .status or r.action == .cancel or r.action == .discover)
                    try self.sessions.call(a, bytes)
                else
                    try self.sessions.elevate(a, bytes)) orelse error.PrivilegedServiceUnavailable;
            }
            if (!self.sessions.isPrivileged()) return error.RootRequired;
            switch (r.action) {
                .execute => return std.json.Stringify.valueAlloc(a, try coordinator.start(self, a, r), .{ .emit_null_optional_fields = false }),
                .discover => {
                    const maintenance = if (self.maintenance) |m|
                        (if (m.discover) |discover| try discover(m.context, a, self.io) else null)
                    else
                        null;
                    const id = (try self.sessions.worker.currentId(a)) orelse (try self.sessions.store.latest(a));
                    const execution = if (id) |value| try coordinator.status(self, a, value) else null;
                    return std.json.Stringify.valueAlloc(a, wire.SessionDiscovery{ .version = proto.API_VERSION, .maintenance = maintenance, .execution = execution }, .{ .emit_null_optional_fields = false });
                },
                .status => {
                    const latest = if (r.session_id == null)
                        (try self.sessions.worker.currentId(a)) orelse (try self.sessions.store.latest(a)) orelse return error.SessionNotFound
                    else
                        null;
                    const result = try coordinator.status(self, a, r.session_id orelse latest.?);
                    if (r.approved_digest) |digest| if (!std.mem.eql(u8, digest, result.plan_digest)) return error.SessionApprovalMismatch;
                    return std.json.Stringify.valueAlloc(a, result, .{ .emit_null_optional_fields = false });
                },
                .cancel => {
                    const id = r.session_id orelse return error.MissingSession;
                    if (self.maintenance) |m| if (m.cancel) |cancel| {
                        if (self.sessions.worker.writeLock()) {
                            defer self.sessions.worker.writeUnlock();
                            if (try cancel(m.context, a, self.io, id, r.approved_digest)) |result| return std.json.Stringify.valueAlloc(a, result, .{ .emit_null_optional_fields = false });
                        }
                    };
                    // Only the worker writes durable progress while an execution is active.
                    _ = self.sessions.worker.cancelExecution(id);
                    return std.json.Stringify.valueAlloc(a, try coordinator.status(self, a, id), .{ .emit_null_optional_fields = false });
                },
                .prepare => {
                    const m = self.maintenance orelse return error.MaintenancePreparationUnavailable;
                    if (!self.sessions.worker.writeLock()) return error.ExecutionInProgress;
                    defer self.sessions.worker.writeUnlock();
                    const draft = r.draft orelse return error.MissingDraft;
                    const snapshot = try self.disk.query(a);
                    const validated = try @import("../planning/planner.zig").validate(a, snapshot, draft, &self.disk);
                    if (!std.mem.eql(u8, validated.digest, r.approved_digest orelse return error.MissingApproval)) return error.PlanApprovalChanged;
                    for (validated.diagnostics) |diagnostic| if (diagnostic.severity == .@"error") return error.PlanNotExecutable;
                    if (!validated.offline_validation_required) return error.NoMaintenanceRequired;
                    return std.json.Stringify.valueAlloc(a, try m.prepare(m.context, a, self.io, snapshot, validated), .{ .emit_null_optional_fields = false });
                },
                .reboot => {
                    const m = self.maintenance orelse return error.MaintenancePreparationUnavailable;
                    if (!self.sessions.worker.writeLock()) return error.ExecutionInProgress;
                    defer self.sessions.worker.writeUnlock();
                    const id = r.session_id orelse return error.MissingSession;
                    const approved = r.approved_digest orelse return error.MissingApproval;
                    _ = try proto.hexDigest(id);
                    _ = try proto.hexDigest(approved);
                    return std.json.Stringify.valueAlloc(a, try m.reboot(m.context, a, self.io, id, approved), .{ .emit_null_optional_fields = false });
                },
                .complete => {
                    const m = self.maintenance orelse return error.NoCompletionReceipt;
                    if (!self.sessions.worker.writeLock()) return error.ExecutionInProgress;
                    defer self.sessions.worker.writeUnlock();
                    if (r.session_id) |id| _ = try proto.hexDigest(id);
                    return std.json.Stringify.valueAlloc(a, try m.complete(m.context, a, self.io, r.session_id), .{ .emit_null_optional_fields = false });
                },
                else => unreachable,
            }
        }
        pub fn replyError(self: *Self, a: std.mem.Allocator, err: anyerror) []const u8 {
            const message = if (err == error.HostPreflightFailed) self.disk.failureMessage(err) else @errorName(err);
            return std.json.Stringify.valueAlloc(a, .{ .@"error" = @errorName(err), .message = message }, .{ .emit_null_optional_fields = false }) catch "{\"error\":\"OutOfMemory\",\"message\":\"Cannot encode error response\"}";
        }
        pub fn respond(self: *Self, a: std.mem.Allocator, bytes: []const u8, access: Access) []const u8 {
            return self.dispatch(a, bytes, access) catch |err| self.replyError(a, err);
        }
        fn privilegedRequest(context: ?*anyopaque, a: std.mem.Allocator, bytes: []const u8) []const u8 {
            const self: *Self = @ptrCast(@alignCast(context.?));
            return self.respond(a, bytes, .privileged);
        }
        pub fn serve(self: *Self) !u8 {
            return self.sessions.serve(self.io, self, privilegedRequest);
        }
    };
}

fn parseRequest(a: std.mem.Allocator, bytes: []const u8) !proto.wire.PrivilegedRequest {
    if (bytes.len > MAX_BYTES) return error.RequestTooLarge;
    const request = try std.json.parseFromSliceLeaky(proto.wire.PrivilegedRequest, a, bytes, .{});
    if (request.version != proto.API_VERSION) return error.UnsupportedProtocolVersion;
    return request;
}

const CURRENT_VERSION = std.fmt.comptimePrint("{d}", .{proto.API_VERSION});
const PREVIOUS_VERSION = std.fmt.comptimePrint("{d}", .{proto.API_VERSION - 1});

test "privileged request accepts only the current contract and known actions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try parseRequest(a, "{\"version\":" ++ CURRENT_VERSION ++ ",\"action\":\"inventory\"}");
    try std.testing.expectEqual(.inventory, request.action);
    try std.testing.expectError(error.UnsupportedProtocolVersion, parseRequest(a, "{\"version\":" ++ PREVIOUS_VERSION ++ ",\"action\":\"inventory\"}"));
    try std.testing.expectError(error.InvalidEnumTag, parseRequest(a, "{\"version\":" ++ CURRENT_VERSION ++ ",\"action\":\"shell\"}"));
    try std.testing.expectError(error.UnknownField, parseRequest(a, "{\"version\":" ++ CURRENT_VERSION ++ ",\"action\":\"execute\",\"command\":\"arbitrary\"}"));
    try std.testing.expectError(error.DuplicateField, parseRequest(a, "{\"version\":" ++ CURRENT_VERSION ++ ",\"version\":" ++ CURRENT_VERSION ++ ",\"action\":\"inventory\"}"));
}

test "privileged request rejects oversized input before allocating a JSON tree" {
    const bytes = try std.testing.allocator.alloc(u8, MAX_BYTES + 1);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.RequestTooLarge, parseRequest(std.testing.failing_allocator, bytes));
}
