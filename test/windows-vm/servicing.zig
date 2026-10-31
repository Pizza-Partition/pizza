//! Native preparation of an immutable, offline Windows test baseline.
const std = @import("std");
const n = @import("core/platform/windows/native.zig");
const a = n.win32.advapi32;
const r = n.win32.system.registry;
const s = n.win32.system.services;
const Status = @import("agent_protocol.zig").ServicingStatus;
const NAMES = .{ "TrustedInstaller", "wuauserv", "UsoSvc", "DoSvc" };

fn exists(comptime path: []const u8) !bool {
    var key: ?r.HKEY = null;
    const rc = a.RegOpenKeyExW(r.HKEY_LOCAL_MACHINE, n.wideLiteral(path), 0, r.KEY_READ, &key);
    if (rc == .ERROR_FILE_NOT_FOUND or rc == .ERROR_PATH_NOT_FOUND) return false;
    if (rc != .NO_ERROR) return error.ServicingRegistryUnavailable;
    _ = a.RegCloseKey(key);
    return true;
}
fn dword(comptime path: []const u8, comptime name: []const u8, value: u32) !void {
    var key: ?r.HKEY = null;
    if (a.RegCreateKeyExW(r.HKEY_LOCAL_MACHINE, n.wideLiteral(path), 0, null, .{}, r.KEY_SET_VALUE, null, &key, null) != .NO_ERROR) return error.UpdatePolicyWriteDenied;
    defer _ = a.RegCloseKey(key);
    if (a.RegSetValueExW(key, n.wideLiteral(name), 0, .DWORD, @ptrCast(&value), 4) != .NO_ERROR) return error.UpdatePolicyWriteDenied;
    var actual: u32 = 0;
    var size: u32 = 4;
    if (a.RegGetValueW(r.HKEY_LOCAL_MACHINE, n.wideLiteral(path), n.wideLiteral(name), .{ .RT_REG_DWORD = 1 }, null, &actual, &size) != .NO_ERROR or actual != value or size != 4) return error.UpdatePolicyReadbackFailed;
}
const Service = struct { running: bool, disabled: bool };
fn service(comptime name: []const u8, disable: bool) !Service {
    const manager = a.OpenSCManagerW(null, null, s.SC_MANAGER_CONNECT);
    if (manager == 0) return error.ServiceManagerUnavailable;
    defer _ = a.CloseServiceHandle(manager);
    const handle = a.OpenServiceW(manager, n.wideLiteral(name), s.SERVICE_QUERY_STATUS | s.SERVICE_QUERY_CONFIG | (if (disable) s.SERVICE_CHANGE_CONFIG | s.SERVICE_STOP else @as(u32, 0)));
    if (handle == 0) {
        if (n.k.GetLastError() == .ERROR_SERVICE_DOES_NOT_EXIST) return .{ .running = false, .disabled = true };
        std.debug.print("Service {s}: Win32={d}\n", .{ name, @backingInt(n.k.GetLastError()) });
        return error.UpdateServiceAccessDenied;
    }
    defer _ = a.CloseServiceHandle(handle);
    var storage: [8192]u8 align(@alignOf(s.QUERY_SERVICE_CONFIGW)) = undefined;
    const config: *s.QUERY_SERVICE_CONFIGW = @ptrCast(&storage);
    var needed: u32 = 0;
    if (a.QueryServiceConfigW(handle, config, storage.len, &needed) == 0) return error.ServiceConfigurationUnavailable;
    if (disable and a.ChangeServiceConfigW(handle, s.SERVICE_NO_CHANGE, .DISABLED, config.dwErrorControl, null, null, null, null, null, null, null) == 0) {
        if (n.k.GetLastError() != .ERROR_ACCESS_DENIED) return error.UpdateServiceDisableDenied;
        // Protected update services may reject SCM changes from SYSTEM. Set
        // next boot's configuration, then require SCM verification after reboot.
        try dword("SYSTEM\\CurrentControlSet\\Services\\" ++ name, "Start", 4);
    }
    var status: s.SERVICE_STATUS_PROCESS = undefined;
    if (a.QueryServiceStatusEx(handle, .O, @ptrCast(&status), @sizeOf(@TypeOf(status)), &needed) == 0) return error.ServiceStatusUnavailable;
    if (disable and status.dwCurrentState != .STOPPED) {
        var stopped: s.SERVICE_STATUS = undefined;
        if (status.dwCurrentState != .STOP_PENDING and a.ControlService(handle, s.SERVICE_CONTROL_STOP, &stopped) == 0 and n.k.GetLastError() != .ERROR_SERVICE_NOT_ACTIVE) {
            if (n.k.GetLastError() == .ERROR_ACCESS_DENIED) return .{ .running = true, .disabled = config.dwStartType == .DISABLED };
            return error.UpdateServiceStopFailed;
        }
        const until = n.k.GetTickCount64() + 30000;
        while (status.dwCurrentState != .STOPPED and n.k.GetTickCount64() < until) {
            n.k.Sleep(100);
            if (a.QueryServiceStatusEx(handle, .O, @ptrCast(&status), @sizeOf(@TypeOf(status)), &needed) == 0) return error.ServiceStatusUnavailable;
        }
        if (status.dwCurrentState != .STOPPED) return error.UpdateServiceStopTimeout;
    }
    if (a.QueryServiceConfigW(handle, config, storage.len, &needed) == 0) return error.ServiceConfigurationUnavailable;
    return .{ .running = status.dwCurrentState != .STOPPED, .disabled = config.dwStartType == .DISABLED };
}
pub fn inspect() !Status {
    var disabled = true;
    var installer = false;
    var running = false;
    inline for (NAMES, 0..) |name, index| {
        const state = try service(name, false);
        disabled = disabled and state.disabled;
        running = running or state.running;
        if (index == 0) installer = state.running;
    }
    return .{
        .reboot_pending = try exists("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending") or
            try exists("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootInProgress") or
            try exists("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired"),
        .installer_running = installer,
        .update_services_running = running,
        .updates_disabled = disabled,
        .uptime_ms = n.k.GetTickCount64(),
    };
}
pub fn freeze() !Status {
    const before = try inspect();
    if (before.reboot_pending or before.installer_running) return error.WindowsServicingStillActive;
    try dword("SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU", "NoAutoUpdate", 1);
    try dword("SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU", "NoAutoRebootWithLoggedOnUsers", 1);
    try dword("SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate", "DisableOSUpgrade", 1);
    try dword("SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate", "DoNotConnectToWindowsUpdateInternetLocations", 1);
    try dword("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Schedule\\Maintenance", "MaintenanceDisabled", 1);
    inline for (NAMES) |name| _ = try service(name, true);
    const after = try inspect();
    // Registry-configured services are verified by SCM on the next boot.
    if (after.installer_running or after.reboot_pending) return error.BaselineUpdatePolicyNotFrozen;
    return after;
}
