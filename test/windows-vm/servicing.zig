//! Native preparation of an immutable, offline Windows test baseline.
const std = @import("std");
const native = @import("core/platform/windows/native.zig");
const advapi32 = native.win32.advapi32;
const registry = native.win32.system.registry;
const services = native.win32.system.services;
const Status = @import("agent_protocol.zig").ServicingStatus;
const NAMES = .{ "TrustedInstaller", "wuauserv", "UsoSvc", "DoSvc" };

fn exists(comptime path: []const u8) !bool {
    var key: ?registry.HKEY = null;
    const rc = advapi32.RegOpenKeyExW(registry.HKEY_LOCAL_MACHINE, native.wideLiteral(path), 0, registry.KEY_READ, &key);
    if (rc == .ERROR_FILE_NOT_FOUND or rc == .ERROR_PATH_NOT_FOUND) return false;
    if (rc != .NO_ERROR) return error.ServicingRegistryUnavailable;
    _ = advapi32.RegCloseKey(key);
    return true;
}
fn dword(comptime path: []const u8, comptime name: []const u8, value: u32) !void {
    var key: ?registry.HKEY = null;
    if (advapi32.RegCreateKeyExW(registry.HKEY_LOCAL_MACHINE, native.wideLiteral(path), 0, null, .{}, registry.KEY_SET_VALUE, null, &key, null) != .NO_ERROR) return error.UpdatePolicyWriteDenied;
    defer _ = advapi32.RegCloseKey(key);
    if (advapi32.RegSetValueExW(key, native.wideLiteral(name), 0, .DWORD, @ptrCast(&value), 4) != .NO_ERROR) return error.UpdatePolicyWriteDenied;
    var actual: u32 = 0;
    var size: u32 = 4;
    if (advapi32.RegGetValueW(registry.HKEY_LOCAL_MACHINE, native.wideLiteral(path), native.wideLiteral(name), .{ .RT_REG_DWORD = 1 }, null, &actual, &size) != .NO_ERROR or actual != value or size != 4) return error.UpdatePolicyReadbackFailed;
}
const Service = struct { running: bool, disabled: bool };
fn service(comptime name: []const u8, disable: bool) !Service {
    const manager = advapi32.OpenSCManagerW(null, null, services.SC_MANAGER_CONNECT);
    if (manager == 0) return error.ServiceManagerUnavailable;
    defer _ = advapi32.CloseServiceHandle(manager);
    const handle = advapi32.OpenServiceW(manager, native.wideLiteral(name), services.SERVICE_QUERY_STATUS | services.SERVICE_QUERY_CONFIG | (if (disable) services.SERVICE_CHANGE_CONFIG | services.SERVICE_STOP else @as(u32, 0)));
    if (handle == 0) {
        if (native.kernel32.GetLastError() == .ERROR_SERVICE_DOES_NOT_EXIST) return .{ .running = false, .disabled = true };
        std.debug.print("Service {s}: Win32={d}\n", .{ name, @backingInt(native.kernel32.GetLastError()) });
        return error.UpdateServiceAccessDenied;
    }
    defer _ = advapi32.CloseServiceHandle(handle);
    var storage: [8192]u8 align(@alignOf(services.QUERY_SERVICE_CONFIGW)) = undefined;
    const config: *services.QUERY_SERVICE_CONFIGW = @ptrCast(&storage);
    var needed: u32 = 0;
    if (advapi32.QueryServiceConfigW(handle, config, storage.len, &needed) == 0) return error.ServiceConfigurationUnavailable;
    if (disable and advapi32.ChangeServiceConfigW(handle, services.SERVICE_NO_CHANGE, .DISABLED, config.dwErrorControl, null, null, null, null, null, null, null) == 0) {
        if (native.kernel32.GetLastError() != .ERROR_ACCESS_DENIED) return error.UpdateServiceDisableDenied;
        // Protected update services may reject SCM changes from SYSTEM. Set
        // next boot's configuration, then require SCM verification after reboot.
        try dword("SYSTEM\\CurrentControlSet\\Services\\" ++ name, "Start", 4);
    }
    var status: services.SERVICE_STATUS_PROCESS = undefined;
    if (advapi32.QueryServiceStatusEx(handle, .O, @ptrCast(&status), @sizeOf(@TypeOf(status)), &needed) == 0) return error.ServiceStatusUnavailable;
    if (disable and status.dwCurrentState != .STOPPED) {
        var stopped: services.SERVICE_STATUS = undefined;
        if (status.dwCurrentState != .STOP_PENDING and advapi32.ControlService(handle, services.SERVICE_CONTROL_STOP, &stopped) == 0 and native.kernel32.GetLastError() != .ERROR_SERVICE_NOT_ACTIVE) {
            if (native.kernel32.GetLastError() == .ERROR_ACCESS_DENIED) return .{ .running = true, .disabled = config.dwStartType == .DISABLED };
            return error.UpdateServiceStopFailed;
        }
        const until = native.kernel32.GetTickCount64() + 30000;
        while (status.dwCurrentState != .STOPPED and native.kernel32.GetTickCount64() < until) {
            native.kernel32.Sleep(100);
            if (advapi32.QueryServiceStatusEx(handle, .O, @ptrCast(&status), @sizeOf(@TypeOf(status)), &needed) == 0) return error.ServiceStatusUnavailable;
        }
        if (status.dwCurrentState != .STOPPED) return error.UpdateServiceStopTimeout;
    }
    if (advapi32.QueryServiceConfigW(handle, config, storage.len, &needed) == 0) return error.ServiceConfigurationUnavailable;
    return .{ .running = status.dwCurrentState != .STOPPED, .disabled = config.dwStartType == .DISABLED };
}
pub fn inspect() !Status {
    var disabled = true;
    var installer = false;
    var running = false;
    inline for (NAMES, 0..) |name, index| {
        const state = try service(name, false);
        if (!state.disabled or state.running) std.debug.print("Baseline service {s}: disabled={}, running={}\n", .{ name, state.disabled, state.running });
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
        .uptime_ms = native.kernel32.GetTickCount64(),
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
