//! Test-only SYSTEM service. COM2 is private to the isolated, NIC-less VM.
const std = @import("std");
const vm_common = @import("vm_common");
const agent_protocol = @import("agent_protocol.zig");
const native = @import("core/platform/windows/native.zig");
const w32 = native.win32;
const adv = w32.advapi32;
const svc = w32.system.services;
const NAME = native.wideLiteral("PizzaVmTestAgent");
var init_: std.process.Init = undefined;
var status_handle: svc.SERVICE_STATUS_HANDLE = 0;
fn control(_: u32) callconv(.winapi) void {}
fn status(state: svc.SERVICE_STATUS_CURRENT_STATE, code: u32) void {
    var s: svc.SERVICE_STATUS = .{ .dwServiceType = .{ .WIN32_OWN_PROCESS = 1 }, .dwCurrentState = state, .dwControlsAccepted = 0, .dwWin32ExitCode = code, .dwServiceSpecificExitCode = 0, .dwCheckPoint = 0, .dwWaitHint = 0 };
    _ = adv.SetServiceStatus(status_handle, &s);
}
fn serviceMain(_: u32, _: ?*?[*:0]u16) callconv(.winapi) void {
    status_handle = adv.RegisterServiceCtrlHandlerW(NAME, control);
    if (status_handle == 0) return;
    status(.RUNNING, 0);
    serve(init_) catch |err| {
        std.Io.Dir.cwd().writeFile(init_.io, .{ .sub_path = "C:\\PizzaVmAgent\\fatal.log", .data = @errorName(err) }) catch {};
        status(.STOPPED, 1);
    };
}
pub fn dispatch(init: std.process.Init) !void {
    init_ = init;
    const table = [_]svc.SERVICE_TABLE_ENTRYW{ .{ .lpServiceName = @constCast(NAME), .lpServiceProc = serviceMain }, .{ .lpServiceName = null, .lpServiceProc = null } };
    if (adv.StartServiceCtrlDispatcherW(&table[0]) == 0) return error.ServiceDispatcherFailed;
}
pub fn install(init: std.process.Init, source: []const u8) !void {
    const a = init.arena.allocator();
    const io = init.io;
    // An interrupted installation may leave the files without the SCM entry.
    try std.Io.Dir.cwd().createDirPath(io, "C:\\PizzaVmAgent");
    try std.Io.Dir.cwd().copyFile(source, .cwd(), "C:\\PizzaVmAgent\\agent.exe", io, .{});
    const inf = try std.fs.path.join(a, &.{ std.fs.path.dirname(source).?, "vioscsi/vioscsi.inf" });
    var reboot: i32 = 0;
    const dll = native.kernel32.LoadLibraryW(native.wideLiteral("C:\\Windows\\System32\\newdev.dll")) orelse return error.DriverInstallerUnavailable;
    defer _ = native.kernel32.FreeLibrary(dll);
    const setup_dll = native.kernel32.LoadLibraryW(native.wideLiteral("C:\\Windows\\System32\\setupapi.dll")) orelse return error.DriverInstallerUnavailable;
    defer _ = native.kernel32.FreeLibrary(setup_dll);
    const noninteractive: @TypeOf(&w32.setupapi.SetupSetNonInteractiveMode) = @ptrCast(native.kernel32.GetProcAddress(setup_dll, "SetupSetNonInteractiveMode") orelse return error.DriverInstallerUnavailable);
    const previous = noninteractive(1);
    defer _ = noninteractive(previous);
    const install_driver: @TypeOf(&w32.newdev.DiInstallDriverW) = @ptrCast(native.kernel32.GetProcAddress(dll, "DiInstallDriverW") orelse return error.DriverInstallerUnavailable);
    if (install_driver(null, try native.wide(a, inf), 0, &reboot) == 0) return error.VirtioDriverInstallationFailed;
    const manager = adv.OpenSCManagerW(null, null, svc.SC_MANAGER_CREATE_SERVICE);
    if (manager == 0) return error.ServiceManagerFailed;
    defer _ = adv.CloseServiceHandle(manager);
    const service = adv.CreateServiceW(manager, NAME, NAME, svc.SERVICE_ALL_ACCESS, .{ .WIN32_OWN_PROCESS = 1 }, .AUTO_START, .NORMAL, native.wideLiteral("C:\\PizzaVmAgent\\agent.exe --service"), null, null, null, null, null);
    if (service == 0) return error.ServiceCreationFailed;
    defer _ = adv.CloseServiceHandle(service);
    if (adv.StartServiceW(service, 0, null) == 0) return error.ServiceStartFailed;
}
fn send(port: native.foundation.HANDLE, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var count: u32 = 0;
        if (native.kernel32.WriteFile(port, bytes[offset..].ptr, @intCast(bytes.len - offset), &count, null) == 0 or count == 0) return error.SerialWriteFailed;
        offset += count;
    }
}
fn execute(init: std.process.Init, request: agent_protocol.Request) !std.process.RunResult {
    const a = init.arena.allocator();
    const executable = if (request.action == .install) blk: {
        var drive: u8 = 'D';
        while (drive <= 'Z') : (drive += 1) {
            const path = try a.print("{c}:\\windows-vm-guest.exe", .{drive});
            if (std.Io.Dir.cwd().statFile(init.io, path, .{})) |_| break :blk path else |_| {}
        }
        return error.ArtifactsMissing;
    } else try std.fs.path.join(a, &.{ request.work, "windows-vm-guest.exe" });
    return vm_common.runAt(a, init.io, null, .inherit, &.{ executable, @tagName(request.action), request.work, request.serial, request.wwn, @tagName(request.case) }, null, 1200);
}
fn serve(init: std.process.Init) !void {
    const port = native.kernel32.CreateFileW(native.wideLiteral("\\\\.\\COM2"), @bitCast(native.GENERIC_READ | native.GENERIC_WRITE), .{}, null, .OPEN_EXISTING, .{}, null);
    if (port == native.foundation.INVALID_HANDLE_VALUE) return error.SerialOpenFailed;
    defer _ = native.kernel32.CloseHandle(port);
    var dcb = std.mem.zeroes(w32.devices.communication.DCB);
    dcb.DCBlength = @sizeOf(@TypeOf(dcb));
    if (native.kernel32.GetCommState(port, &dcb) == 0) return error.SerialConfigurationFailed;
    dcb.BaudRate = 115200;
    dcb.ByteSize = 8;
    dcb.Parity = .NOPARITY;
    dcb.StopBits = .ONESTOPBIT;
    dcb._bitfield = 1; // Binary, no hardware/software flow control.
    if (native.kernel32.SetCommState(port, &dcb) == 0) return error.SerialConfigurationFailed;
    var timeouts: w32.devices.communication.COMMTIMEOUTS = .{ .ReadIntervalTimeout = 50, .ReadTotalTimeoutMultiplier = 0, .ReadTotalTimeoutConstant = 500, .WriteTotalTimeoutMultiplier = 0, .WriteTotalTimeoutConstant = 30000 };
    if (native.kernel32.SetCommTimeouts(port, &timeouts) == 0) return error.SerialConfigurationFailed;
    var line: std.ArrayList(u8) = .empty;
    const a = init.arena.allocator();
    var greeted: i64 = 0;
    while (true) {
        const now = std.Io.Clock.awake.now(init.io).toMilliseconds();
        if (line.items.len == 0 and now - greeted > 2000) {
            try send(port, "PZ_AGENT_READY\n");
            greeted = now;
        }
        var buf: [1024]u8 = undefined;
        var count: u32 = 0;
        if (native.kernel32.ReadFile(port, &buf, buf.len, &count, null) == 0) return error.SerialReadFailed;
        for (buf[0..count]) |ch| {
            if (ch == '\r') continue;
            if (ch != '\n') {
                if (line.items.len >= 4096) return error.RequestTooLarge;
                try line.append(a, ch);
                continue;
            }
            if (line.items.len == 0) continue;
            var request_arena: std.heap.ArenaAllocator = .init(a);
            defer request_arena.deinit();
            const alloc = request_arena.allocator();
            const request = try std.json.parseFromSliceLeaky(agent_protocol.Request, alloc, line.items, .{});
            try request.validate();
            const r = execute(init, request) catch |err| {
                try send(port, try alloc.print("PZ_AGENT:{s}\n", .{try std.json.Stringify.valueAlloc(alloc, agent_protocol.Response{ .id = request.id, .ok = false, .stderr = @errorName(err) }, .{})}));
                line.clearRetainingCapacity();
                continue;
            };
            // Compact JSON keeps one complete response on a single serial line.
            const bytes = try std.json.Stringify.valueAlloc(alloc, agent_protocol.Response{ .id = request.id, .ok = r.term.success(), .stdout = r.stdout, .stderr = r.stderr }, .{});
            try send(port, try alloc.print("PZ_AGENT:{s}\n", .{bytes}));
            line.clearRetainingCapacity();
        }
    }
}
