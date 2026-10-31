//! UAC launch and authenticated client calls. Submitted writes are never replayed.
const std = @import("std");
const n = @import("../native.zig");
const security = @import("security.zig");
const transport = @import("transport.zig");
pub const Readiness = enum { ready, executable_changed, authorization_unavailable };
const LOST = "{\"error\":\"execution_response_lost\",\"message\":\"The helper received a request but its response was lost. Check execution status before retrying.\"}";
pub fn readiness() Readiness {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    _ = security.executable(arena.allocator(), n.k.GetCurrentProcess()) catch return .executable_changed;
    _ = security.identity(arena.allocator(), n.k.GetCurrentProcess()) catch return .authorization_unavailable;
    return .ready;
}
fn connect(a: std.mem.Allocator, owner: security.Identity) !?n.f.HANDLE {
    const name = try security.pipeName(a, owner);
    const until = n.k.GetTickCount64() + 2000;
    const h = while (true) {
        if (n.valid(n.k.CreateFileW(name, @bitCast(n.GENERIC_READ | n.GENERIC_WRITE), .{}, null, .OPEN_EXISTING, n.fs.SECURITY_SQOS_PRESENT, null))) |handle| break handle;
        const code = n.k.GetLastError();
        if (code == .ERROR_FILE_NOT_FOUND or code == .ERROR_PATH_NOT_FOUND) return null;
        if (code != .ERROR_PIPE_BUSY) return error.PipeUnavailable;
        if (n.k.GetTickCount64() >= until) return error.PrivilegedServiceBusy;
        n.k.Sleep(10);
    };
    errdefer n.close(h);
    var pid: u32 = 0;
    if (n.k.GetNamedPipeServerProcessId(h, &pid) == 0) return error.UnauthorizedPeer;
    try security.peer(a, pid, owner, true);
    var mode: n.win32.system.pipes.NAMED_PIPE_MODE = .{ .NOWAIT = 1 };
    if (n.k.SetNamedPipeHandleState(h, &mode, null, null) == 0) return error.PipeUnavailable;
    return h;
}
fn exchange(a: std.mem.Allocator, h: n.f.HANDLE, request: []const u8) ![]const u8 {
    // Once sending begins, every transport failure is ambiguous to the caller.
    transport.send(h, request, transport.REQUEST_LIMIT) catch return a.dupe(u8, LOST);
    const response = transport.receive(a, h, transport.RESPONSE_LIMIT) catch return a.dupe(u8, LOST);
    transport.writeAll(h, &.{1}, transport.deadline()) catch {};
    return response;
}
pub fn call(a: std.mem.Allocator, request: []const u8) !?[]const u8 {
    if (request.len == 0 or request.len > transport.REQUEST_LIMIT) return error.InvalidPipeFrame;
    const owner = try security.identity(a, n.k.GetCurrentProcess());
    const h = (try connect(a, owner)) orelse return null;
    defer n.close(h);
    return try exchange(a, h, request);
}
pub fn elevate(a: std.mem.Allocator, request: []const u8) !?[]const u8 {
    if (try call(a, request)) |response| return response;
    const apartment = n.win32.ole32.CoInitializeEx(null, .{ .APARTMENTTHREADED = 1 });
    if (apartment.failed and @as(u32, @bitCast(apartment)) != 0x80010106) return error.AuthorizationUnavailable;
    defer if (!apartment.failed) n.win32.ole32.CoUninitialize();
    const path = try security.executable(a, n.k.GetCurrentProcess());
    const arguments = try n.wide(a, try a.print("privileged-exec --parent {d}", .{n.k.GetCurrentProcessId()}));
    var info = std.mem.zeroes(n.win32.ui.shell.SHELLEXECUTEINFOW);
    info.cbSize = @sizeOf(@TypeOf(info));
    info.fMask = n.win32.ui.shell.SEE_MASK_NOCLOSEPROCESS | n.win32.ui.shell.SEE_MASK_NOASYNC;
    info.lpVerb = n.wideLiteral("runas");
    info.lpFile = path;
    info.lpParameters = arguments;
    info.nShow = 0;
    if (n.win32.shell32.ShellExecuteExW(&info) == 0) return error.AuthorizationFailed;
    const process = info.hProcess orelse return error.AuthorizationFailed;
    defer n.close(process);
    const until = n.k.GetTickCount64() + 60_000;
    while (n.k.GetTickCount64() < until) {
        if (try call(a, request)) |response| return response;
        if (n.k.WaitForSingleObject(process, 0) == .NO_ERROR) return error.PrivilegedServiceUnavailable;
        n.k.Sleep(25);
    }
    return error.PrivilegedServiceUnavailable;
}
