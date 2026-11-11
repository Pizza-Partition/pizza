//! Windows authorization boundary. The application owns no Windows-specific state.
const Session = @This();
const std = @import("std");
const native = @import("native.zig");
const security = @import("ipc/security.zig");
const transport = @import("ipc/transport.zig");
const client = @import("ipc/client.zig");
pub const Handler = *const fn (?*anyopaque, std.mem.Allocator, []const u8) []const u8;
parent_pid: ?u32 = null,
worker: @import("../../execution/worker.zig") = .{},
store: @import("ipc/store.zig") = .{},
pub fn isPrivileged(_: *const Session) bool {
    return security.elevated();
}
pub fn readiness(_: *const Session) client.Readiness {
    return client.readiness();
}
pub fn call(_: *Session, a: std.mem.Allocator, request: []const u8) !?[]const u8 {
    return client.call(a, request);
}
pub fn elevate(_: *Session, a: std.mem.Allocator, request: []const u8) !?[]const u8 {
    return client.elevate(a, request);
}

/// A direct elevated CLI has no IPC server to own its record lifetime.
pub fn openRecords(self: *Session, a: std.mem.Allocator) !void {
    try self.store.init(a, try security.identity(a, native.kernel32.GetCurrentProcess()));
}
pub fn closeRecords(self: *Session) void {
    self.store.deinit();
}

pub fn serve(self: *Session, io: std.Io, context: ?*anyopaque, handler: Handler) !u8 {
    var lifetime: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer lifetime.deinit();
    const a = lifetime.allocator();
    const owner = try security.identity(a, native.kernel32.GetCurrentProcess());
    if (!owner.elevated) return error.AdministratorRequired;
    try security.peer(a, self.parent_pid orelse return error.MissingAuthorizationParent, owner, false);
    try self.store.init(a, owner);
    defer self.store.deinit();
    const descriptor = try security.Descriptor.init(a, try a.print("D:P(A;;GA;;;SY)(A;;GA;;;{s})", .{owner.sid}));
    defer descriptor.deinit();
    var attributes = descriptor.attributes();
    // One retained instance excludes another server for the entire helper lifetime.
    const pipe = native.kernel32.CreateNamedPipeW(try security.pipeName(a, owner), native.PIPE_SERVER_FLAGS, .{ .NOWAIT = 1, .REJECT_REMOTE_CLIENTS = 1 }, 1, 65536, 65536, 0, &attributes);
    if (pipe == native.foundation.INVALID_HANDLE_VALUE) return error.PipeUnavailable;
    defer _ = native.kernel32.CloseHandle(pipe);
    // A transport failure must not close records while a write is still running.
    defer self.worker.wait(io);
    var last_activity = native.kernel32.GetTickCount64();
    while (self.worker.busy() or native.kernel32.GetTickCount64() - last_activity < 300_000) {
        const connected = native.kernel32.ConnectNamedPipe(pipe, null) != 0;
        const code = if (connected) native.foundation.WIN32_ERROR.NO_ERROR else native.kernel32.GetLastError();
        if (!connected and code != .ERROR_PIPE_CONNECTED) {
            if (code != .ERROR_PIPE_LISTENING and code != .ERROR_NO_DATA) return error.PipeUnavailable;
            if (code == .ERROR_NO_DATA) _ = native.kernel32.DisconnectNamedPipe(pipe);
            native.kernel32.Sleep(10);
            continue;
        }
        defer _ = native.kernel32.DisconnectNamedPipe(pipe);
        last_activity = native.kernel32.GetTickCount64();
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        var pid: u32 = 0;
        if (native.kernel32.GetNamedPipeClientProcessId(pipe, &pid) == 0) continue;
        security.peer(arena.allocator(), pid, owner, false) catch continue;
        const request = transport.receive(arena.allocator(), pipe, transport.REQUEST_LIMIT) catch continue;
        const response = handler(context, arena.allocator(), request);
        transport.send(pipe, response, transport.RESPONSE_LIMIT) catch continue;
        // DisconnectNamedPipe discards unread bytes; the ACK confirms consumption.
        var ack: [1]u8 = undefined;
        transport.readExact(pipe, &ack, transport.deadline()) catch {};
    }
    return 0;
}
