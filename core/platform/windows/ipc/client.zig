//! UAC launch and authenticated client calls. Submitted writes are never replayed.
const std = @import("std");
const native = @import("../native.zig");
const security = @import("security.zig");
const transport = @import("transport.zig");
pub const Readiness = enum { ready, executable_changed, authorization_unavailable };
const LOST = "{\"error\":\"execution_response_lost\",\"message\":\"The helper received a request but its response was lost. Check execution status before retrying.\"}";
pub fn readiness() Readiness {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    _ = security.executable(arena.allocator(), native.kernel32.GetCurrentProcess()) catch return .executable_changed;
    _ = security.identity(arena.allocator(), native.kernel32.GetCurrentProcess()) catch return .authorization_unavailable;
    return .ready;
}
fn connect(a: std.mem.Allocator, owner: security.Identity) !?native.foundation.HANDLE {
    const name = try security.pipeName(a, owner);
    const until = native.kernel32.GetTickCount64() + 2000;
    const h = while (true) {
        const handle = native.kernel32.CreateFileW(name, @bitCast(native.GENERIC_READ | native.GENERIC_WRITE), .{}, null, .OPEN_EXISTING, native.fs.SECURITY_SQOS_PRESENT, null);
        if (handle != native.foundation.INVALID_HANDLE_VALUE) break handle;
        const code = native.kernel32.GetLastError();
        if (code == .ERROR_FILE_NOT_FOUND or code == .ERROR_PATH_NOT_FOUND) return null;
        if (code != .ERROR_PIPE_BUSY) return error.PipeUnavailable;
        if (native.kernel32.GetTickCount64() >= until) return error.PrivilegedServiceBusy;
        native.kernel32.Sleep(10);
    };
    errdefer _ = native.kernel32.CloseHandle(h);
    var pid: u32 = 0;
    if (native.kernel32.GetNamedPipeServerProcessId(h, &pid) == 0) return error.UnauthorizedPeer;
    try security.peer(a, pid, owner, true);
    var mode: native.win32.system.pipes.NAMED_PIPE_MODE = .{ .NOWAIT = 1 };
    if (native.kernel32.SetNamedPipeHandleState(h, &mode, null, null) == 0) return error.PipeUnavailable;
    return h;
}
fn exchange(a: std.mem.Allocator, h: native.foundation.HANDLE, request: []const u8) ![]const u8 {
    // Once sending begins, every transport failure is ambiguous to the caller.
    transport.send(h, request, transport.REQUEST_LIMIT) catch return a.dupe(u8, LOST);
    const response = transport.receive(a, h, transport.RESPONSE_LIMIT) catch return a.dupe(u8, LOST);
    transport.writeAll(h, &.{1}, transport.deadline()) catch {};
    return response;
}
pub fn call(a: std.mem.Allocator, request: []const u8) !?[]const u8 {
    if (request.len == 0 or request.len > transport.REQUEST_LIMIT) return error.InvalidPipeFrame;
    const owner = try security.identity(a, native.kernel32.GetCurrentProcess());
    const h = (try connect(a, owner)) orelse return null;
    defer _ = native.kernel32.CloseHandle(h);
    return try exchange(a, h, request);
}
pub fn elevate(a: std.mem.Allocator, request: []const u8) !?[]const u8 {
    if (try call(a, request)) |response| return response;
    const apartment = native.win32.ole32.CoInitializeEx(null, .{ .APARTMENTTHREADED = 1 });
    if (apartment.failed and !std.meta.eql(apartment, native.foundation.RPC_E_CHANGED_MODE)) return error.AuthorizationUnavailable;
    defer if (!apartment.failed) native.win32.ole32.CoUninitialize();
    const path = try security.executable(a, native.kernel32.GetCurrentProcess());
    const arguments = try native.wide(a, try a.print("privileged-exec --parent {d}", .{native.kernel32.GetCurrentProcessId()}));
    var info = std.mem.zeroes(native.win32.ui.shell.SHELLEXECUTEINFOW);
    info.cbSize = @sizeOf(@TypeOf(info));
    info.fMask = native.win32.ui.shell.SEE_MASK_NOCLOSEPROCESS | native.win32.ui.shell.SEE_MASK_NOASYNC;
    info.lpVerb = native.wideLiteral("runas");
    info.lpFile = path;
    info.lpParameters = arguments;
    info.nShow = 0;
    if (native.win32.shell32.ShellExecuteExW(&info) == 0) return error.AuthorizationFailed;
    const process = info.hProcess orelse return error.AuthorizationFailed;
    defer _ = native.kernel32.CloseHandle(process);
    const until = native.kernel32.GetTickCount64() + 60_000;
    while (native.kernel32.GetTickCount64() < until) {
        if (try call(a, request)) |response| return response;
        if (native.kernel32.WaitForSingleObject(process, 0) == .NO_ERROR) return error.PrivilegedServiceUnavailable;
        native.kernel32.Sleep(25);
    }
    return error.PrivilegedServiceUnavailable;
}
