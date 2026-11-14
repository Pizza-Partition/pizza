//! Application requests and authorization routing; no WebUI or operating-system APIs.
const json = @import("../json.zig").json;
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
        maintenance: @import("../boot/ports.zig").Controller,

        /// UI and CLI share this read-only editor endpoint. Elevated discovery
        /// uses the existing privileged inventory channel, never client data.
        pub fn plan(self: *Self, a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
            const editor = @import("../planning/editor.zig");
            if (bytes.len > MAX_BYTES) return error.RequestTooLarge;
            const request = try std.json.parseFromSliceLeaky(editor.Request, a, bytes, .{});
            if (request.version != proto.API_VERSION) return error.UnsupportedProtocolVersion;
            const snapshot = if (request.elevated and !self.sessions.isPrivileged()) blk: {
                const message = try json(a, wire.PrivilegedRequest{ .version = proto.API_VERSION, .action = .inventory, .elevated = true });
                const response = try self.dispatch(a, message, .local);
                const envelope = try std.json.parseFromSliceLeaky(std.json.Value, a, response, .{});
                if (envelope == .object and envelope.object.get("error") != null) return response;
                break :blk try std.json.parseFromSliceLeaky(wire.InventorySnapshot, a, response, .{});
            } else try self.disk.query(a);
            var result = try editor.edit(a, self.io, snapshot, request);
            if (request.review) result.validated = try @import("../planning/planner.zig").validate(a, snapshot, result.draft, &self.disk);
            return json(a, result);
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
            return json(a, .{ .version = proto.API_VERSION, .protocol = proto.API_VERSION, .writes_enabled = readiness == .ready, .maintenance_available = self.maintenance.available, .execution_issue = issue, .formats = formats.items, .capabilities = .{ "inventory", "plan", "validate", "execute", "status", "cancel", "discover" } });
        }

        pub fn dispatch(self: *Self, a: std.mem.Allocator, bytes: []const u8, access: Access) ![]const u8 {
            const r = try parseRequest(a, bytes);
            if (r.elevated and access == .local)
                return try self.sessions.elevate(a, bytes) orelse error.PrivilegedServiceUnavailable;
            switch (r.action) {
                .inventory => return json(a, try self.disk.query(a)),
                .validate => return json(a, try @import("../planning/planner.zig").validate(a, try self.disk.query(a), r.draft orelse return error.MissingDraft, &self.disk)),
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
                .execute => return json(a, try coordinator.start(self, a, r)),
                .discover => {
                    const m = self.maintenance;
                    const maintenance = try m.discover(m.context, a, self.io);
                    const id = (try self.sessions.worker.currentId(a)) orelse (try self.sessions.store.latest(a));
                    const execution = if (id) |value| try coordinator.status(self, a, value) else null;
                    return json(a, wire.SessionDiscovery{ .version = proto.API_VERSION, .maintenance = maintenance, .execution = execution });
                },
                .status => {
                    const latest = if (r.session_id == null)
                        (try self.sessions.worker.currentId(a)) orelse (try self.sessions.store.latest(a)) orelse return error.SessionNotFound
                    else
                        null;
                    const result = try coordinator.status(self, a, r.session_id orelse latest.?);
                    if (r.approved_digest) |digest| if (!std.mem.eql(u8, digest, result.plan_digest)) return error.SessionApprovalMismatch;
                    return json(a, result);
                },
                .cancel => {
                    const id = r.session_id orelse return error.MissingSession;
                    const m = self.maintenance;
                    if (m.available) {
                        if (self.sessions.worker.writeLock()) {
                            defer self.sessions.worker.writeUnlock();
                            if (try m.cancel(m.context, a, self.io, id, r.approved_digest)) |result| return json(a, result);
                        }
                    }
                    // Only the worker writes durable progress while an execution is active.
                    _ = self.sessions.worker.cancelExecution(id);
                    return json(a, try coordinator.status(self, a, id));
                },
                .prepare => {
                    const m = self.maintenance;
                    if (!m.available) return error.MaintenancePreparationUnavailable;
                    if (!self.sessions.worker.writeLock()) return error.ExecutionInProgress;
                    defer self.sessions.worker.writeUnlock();
                    const approval = try @import("approval.zig").check(self, a, r);
                    const snapshot = approval.snapshot;
                    const validated = approval.validated;
                    for (validated.diagnostics) |diagnostic| if (diagnostic.severity == .@"error") return error.PlanNotExecutable;
                    if (!validated.offline_validation_required) return error.NoMaintenanceRequired;
                    return json(a, try m.prepare(m.context, a, self.io, snapshot, validated));
                },
                .reboot => {
                    const m = self.maintenance;
                    if (!m.available) return error.MaintenancePreparationUnavailable;
                    if (!self.sessions.worker.writeLock()) return error.ExecutionInProgress;
                    defer self.sessions.worker.writeUnlock();
                    const id = r.session_id orelse return error.MissingSession;
                    const approved = r.approved_digest orelse return error.MissingApproval;
                    return json(a, try m.reboot(m.context, a, self.io, id, approved));
                },
                .complete => {
                    const m = self.maintenance;
                    if (!m.available) return error.NoCompletionReceipt;
                    if (!self.sessions.worker.writeLock()) return error.ExecutionInProgress;
                    defer self.sessions.worker.writeUnlock();
                    return json(a, try m.complete(m.context, a, self.io, r.session_id));
                },
                else => unreachable,
            }
        }
        pub fn replyError(self: *Self, a: std.mem.Allocator, err: anyerror) []const u8 {
            const message = if (err == error.HostPreflightFailed) self.disk.failureMessage(err) else @errorName(err);
            return json(a, .{ .@"error" = @errorName(err), .message = message }) catch "{\"error\":\"OutOfMemory\",\"message\":\"Cannot encode error response\"}";
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
