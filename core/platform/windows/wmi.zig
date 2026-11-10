//! Thread-scoped WMI resources and typed values; no disk policy or application imports.
const std = @import("std");
const native = @import("native.zig");
const win = native.win32;
const api = win.system.wmi;
const com = win.system.com;
const ole = win.oleaut32;
const log = std.log.scoped(.wmi);
pub const STORAGE_NAMESPACE = "ROOT\\Microsoft\\Windows\\Storage";
pub const BITLOCKER_NAMESPACE = "ROOT\\CIMV2\\Security\\MicrosoftVolumeEncryption";

pub fn checkHresult(hr: win.zig.HRESULT) !void {
    if (hr.failed) {
        log.err("HRESULT=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        return error.WindowsWmiFailed;
    }
}

pub const ComScope = struct {
    owned: bool,

    pub fn init() !ComScope {
        const hr = win.ole32.CoInitializeEx(null, .{});
        if (std.meta.eql(hr, win.foundation.RPC_E_CHANGED_MODE)) return .{ .owned = false };
        try checkHresult(hr);
        errdefer win.ole32.CoUninitialize();
        const security = win.ole32.CoInitializeSecurity(null, -1, null, null, .DEFAULT, .IMPERSONATE, null, .NONE, null);
        if (!std.meta.eql(security, win.foundation.RPC_E_TOO_LATE)) try checkHresult(security);
        return .{ .owned = true };
    }

    pub fn deinit(self: ComScope) void {
        if (self.owned) win.ole32.CoUninitialize();
    }
};

fn bstr(a: std.mem.Allocator, text: []const u8) !*u16 {
    const value = try native.wide(a, text);
    defer a.free(value);
    return ole.SysAllocString(value) orelse error.OutOfMemory;
}

fn string(a: std.mem.Allocator, value: ?*u16) ![]const u8 {
    const s = value orelse return a.dupe(u8, "");
    const len = ole.SysStringLen(s);
    if (len > 1024 * 1024) return error.WindowsValueTooLarge;
    return std.unicode.utf16LeToUtf8Alloc(a, @as([*]const u16, @ptrCast(s))[0..len]);
}

pub const Object = struct {
    ptr: *api.IWbemClassObject,

    pub fn deinit(self: Object) void {
        _ = self.ptr.IUnknown.Release();
    }

    fn get(self: Object, comptime name: []const u8) !com.VARIANT {
        var value = std.mem.zeroes(com.VARIANT);
        checkHresult(self.ptr.Get(native.wideLiteral(name), 0, &value, null, null)) catch return error.WindowsPropertyUnavailable;
        return value;
    }

    pub fn text(self: Object, a: std.mem.Allocator, comptime name: []const u8) !?[]const u8 {
        var value = try self.get(name);
        defer _ = ole.VariantClear(&value);
        const v = value.Anonymous.Anonymous;
        return switch (v.vt) {
            .EMPTY, .NULL => null,
            .BSTR => try string(a, v.Anonymous.bstrVal),
            else => error.WindowsPropertyTypeMismatch,
        };
    }

    pub fn number(self: Object, comptime name: []const u8) !u64 {
        var value = try self.get(name);
        defer _ = ole.VariantClear(&value);
        const v = value.Anonymous.Anonymous;
        return switch (v.vt) {
            .UI1 => v.Anonymous.bVal,
            .UI2 => v.Anonymous.uiVal,
            .UI4 => v.Anonymous.ulVal,
            .UI8 => v.Anonymous.ullVal,
            // WMI maps CIM_UINT32 to VT_I4, retaining the unsigned bit pattern.
            .I4 => @as(u32, @bitCast(v.Anonymous.lVal)),
            .I2 => std.math.cast(u64, v.Anonymous.iVal) orelse return error.InvalidWindowsNumber,
            .I8 => std.math.cast(u64, v.Anonymous.llVal) orelse return error.InvalidWindowsNumber,
            .BSTR => blk: {
                const s = v.Anonymous.bstrVal orelse return error.InvalidWindowsNumber;
                const len = ole.SysStringLen(s);
                if (len == 0 or len > 20) return error.InvalidWindowsNumber;
                var digits: [20]u8 = undefined;
                for (@as([*]const u16, @ptrCast(s))[0..len], 0..) |ch, i| digits[i] = std.math.cast(u8, ch) orelse return error.InvalidWindowsNumber;
                break :blk try std.fmt.parseInt(u64, digits[0..len], 10);
            },
            else => error.WindowsPropertyTypeMismatch,
        };
    }

    pub fn boolean(self: Object, comptime name: []const u8) !bool {
        var value = try self.get(name);
        defer _ = ole.VariantClear(&value);
        const v = value.Anonymous.Anonymous;
        if (v.vt != .BOOL) return error.WindowsPropertyTypeMismatch;
        return v.Anonymous.boolVal != 0;
    }

    pub fn texts(self: Object, a: std.mem.Allocator, comptime name: []const u8) ![]const []const u8 {
        var value = try self.get(name);
        defer _ = ole.VariantClear(&value);
        const v = value.Anonymous.Anonymous;
        if (v.vt == .NULL or v.vt == .EMPTY) return &.{};
        if (@backingInt(v.vt) != @backingInt(com.VT_ARRAY) | @backingInt(com.VT_BSTR)) return error.WindowsPropertyTypeMismatch;
        const array = v.Anonymous.parray orelse return error.WindowsPropertyTypeMismatch;
        if (ole.SafeArrayGetDim(array) != 1) return error.WindowsPropertyTypeMismatch;
        var low: i32 = 0;
        var high: i32 = 0;
        if (ole.SafeArrayGetLBound(array, 1, &low).failed or ole.SafeArrayGetUBound(array, 1, &high).failed or high < low or @as(i64, high) - low > 4096) return error.InvalidWindowsArray;
        var result: std.ArrayList([]const u8) = .empty;
        var index = low;
        while (index <= high) : (index += 1) {
            var s: ?*u16 = null;
            if (ole.SafeArrayGetElement(array, &index, @ptrCast(&s)).failed) return error.InvalidWindowsArray;
            defer ole.SysFreeString(s);
            try result.append(a, try string(a, s));
        }
        return result.toOwnedSlice(a);
    }
};
pub const Enumerator = struct {
    ptr: *api.IEnumWbemClassObject,
    count: usize = 0,
    pub fn deinit(self: Enumerator) void {
        _ = self.ptr.IUnknown.Release();
    }
    pub fn next(self: *Enumerator) !?Object {
        var object: [1]?*api.IWbemClassObject = .{null};
        var count: u32 = 0;
        const hr = self.ptr.Next(30_000, 1, &object, &count);
        checkHresult(hr) catch return error.WindowsEnumerationFailed;
        if (count == 0) return if (std.meta.eql(hr, win.foundation.S_FALSE)) null else error.WindowsEnumerationTimeout;
        self.count += 1;
        if (self.count > 16384) {
            if (object[0]) |p| _ = p.IUnknown.Release();
            return error.WindowsEnumerationTooLarge;
        }
        return .{ .ptr = object[0] orelse return error.InvalidWindowsResponse };
    }
};

pub const Argument = struct {
    name: [:0]const u16,
    value: union(enum) {
        text: []const u8,
        uint64: u64,
        uint32: u32,
        boolean: bool,
    },
};

pub const Connection = struct {
    ptr: *api.IWbemServices,
    pub fn init(a: std.mem.Allocator, namespace: []const u8) !Connection {
        var locator: *api.IWbemLocator = undefined;
        try checkHresult(win.ole32.CoCreateInstance(api.CLSID_WbemLocator, null, .{ .INPROC_SERVER = 1 }, api.IID_IWbemLocator, @ptrCast(&locator)));
        defer _ = locator.IUnknown.Release();
        const path = try bstr(a, namespace);
        defer ole.SysFreeString(path);
        var services: ?*api.IWbemServices = null;
        try checkHresult(locator.ConnectServer(path, null, null, null, @backingInt(api.WBEM_FLAG_CONNECT_USE_MAX_WAIT), null, null, &services));
        const ptr = services orelse return error.InvalidWindowsResponse;
        errdefer _ = ptr.IUnknown.Release();
        try checkHresult(win.ole32.CoSetProxyBlanket(&ptr.IUnknown, win.system.rpc.RPC_C_AUTHN_WINNT, win.system.rpc.RPC_C_AUTHZ_NONE, null, .PKT_PRIVACY, .IMPERSONATE, null, .NONE));
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: Connection) void {
        _ = self.ptr.IUnknown.Release();
    }

    pub fn query(self: Connection, a: std.mem.Allocator, query_text: []const u8) !Enumerator {
        const language = try bstr(a, "WQL");
        defer ole.SysFreeString(language);
        const sql = try bstr(a, query_text);
        defer ole.SysFreeString(sql);
        var result: ?*api.IEnumWbemClassObject = null;
        try checkHresult(self.ptr.ExecQuery(language, sql, .{ .FLAG_FORWARD_ONLY = 1, .FLAG_RETURN_IMMEDIATELY = 1 }, null, &result));
        const ptr = result orelse return error.InvalidWindowsResponse;
        errdefer _ = ptr.IUnknown.Release();
        try checkHresult(win.ole32.CoSetProxyBlanket(&ptr.IUnknown, 10, 0, null, .PKT_PRIVACY, .IMPERSONATE, null, .NONE));
        return .{ .ptr = ptr };
    }

    pub fn method(self: Connection, a: std.mem.Allocator, object: Object, comptime name: []const u8, args: []const Argument) !Object {
        const path = try bstr(a, (try object.text(a, "__PATH")) orelse return error.WindowsObjectPathUnavailable);
        defer ole.SysFreeString(path);
        const method_name = try bstr(a, name);
        defer ole.SysFreeString(method_name);
        var input: ?*api.IWbemClassObject = null;
        defer {
            if (input) |p| {
                _ = p.IUnknown.Release();
            }
        }
        if (args.len != 0) {
            const class_name = try bstr(a, (try object.text(a, "__CLASS")) orelse return error.WindowsClassUnavailable);
            defer ole.SysFreeString(class_name);
            var class: ?*api.IWbemClassObject = null;
            try checkHresult(self.ptr.GetObject(class_name, 0, null, &class, null));
            const definition: Object = .{ .ptr = class orelse return error.WindowsClassUnavailable };
            defer definition.deinit();
            var signature: ?*api.IWbemClassObject = null;
            try checkHresult(definition.ptr.GetMethod(native.wideLiteral(name), 0, &signature, null));
            defer {
                if (signature) |p| {
                    _ = p.IUnknown.Release();
                }
            }
            try checkHresult((signature orelse return error.WindowsMethodUnavailable).SpawnInstance(0, &input));
            for (args) |arg| {
                var v = std.mem.zeroes(com.VARIANT);
                defer _ = ole.VariantClear(&v);
                const payload = &v.Anonymous.Anonymous;
                switch (arg.value) {
                    .text => |s| {
                        payload.vt = .BSTR;
                        payload.Anonymous.bstrVal = try bstr(a, s);
                    },
                    .uint64 => |number| {
                        payload.vt = .BSTR;
                        payload.Anonymous.bstrVal = try bstr(a, try a.print("{d}", .{number}));
                    },
                    .uint32 => |number| {
                        payload.vt = .I4;
                        payload.Anonymous.lVal = @bitCast(number);
                    },
                    .boolean => |b| {
                        payload.vt = .BOOL;
                        payload.Anonymous.boolVal = if (b) -1 else 0;
                    },
                }
                try checkHresult(input.?.Put(arg.name, 0, &v, 0));
            }
        }
        var output: ?*api.IWbemClassObject = null;
        try checkHresult(self.ptr.ExecMethod(path, method_name, 0, null, input, &output, null));
        const result: Object = .{ .ptr = output orelse return error.InvalidWindowsResponse };
        errdefer result.deinit();
        const status = try result.number("ReturnValue");
        if (status != 0) {
            const detail = result.text(a, "ExtendedStatus") catch null;
            defer if (detail) |s| a.free(s);
            log.err("{s}: ReturnValue={d}, {s}", .{ name, status, detail orelse "" });
            return error.WindowsStorageMethodFailed;
        }
        return result;
    }
};
