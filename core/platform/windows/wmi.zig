//! Thread-scoped WMI resources and typed values; no disk policy or application imports.
const std = @import("std");
const n = @import("native.zig");
const win = n.win32;
const api = win.system.wmi;
const com = win.system.com;
const ole = win.oleaut32;
pub const STORAGE_NAMESPACE = "ROOT\\Microsoft\\Windows\\Storage";
pub const BITLOCKER_NAMESPACE = "ROOT\\CIMV2\\Security\\MicrosoftVolumeEncryption";

pub const Failure = struct {
    hresult: i32 = 0,
    return_value: u64 = 0,
    detail: [2048]u8 = undefined,
    len: usize = 0,
    pub fn check(self: *Failure, hr: win.zig.HRESULT) !void {
        if (hr.failed) {
            self.hresult = @bitCast(hr);
            return error.WindowsWmiFailed;
        }
    }
    pub fn message(self: *const Failure, buffer: []u8, err: anyerror) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}: HRESULT=0x{x:0>8}, ReturnValue={d}, {s}", .{ @errorName(err), @as(u32, @bitCast(self.hresult)), self.return_value, self.detail[0..self.len] }) catch @errorName(err);
    }
};
pub const Apartment = struct {
    owned: bool,
    pub fn init(failure: *Failure) !Apartment {
        const hr = win.ole32.CoInitializeEx(null, .{});
        if (@as(u32, @bitCast(hr)) == 0x80010106) return .{ .owned = false };
        try failure.check(hr);
        errdefer win.ole32.CoUninitialize();
        const security = win.ole32.CoInitializeSecurity(null, -1, null, null, .DEFAULT, .IMPERSONATE, null, .NONE, null);
        if (@as(u32, @bitCast(security)) != 0x80010119) try failure.check(security);
        return .{ .owned = true };
    }
    pub fn deinit(self: Apartment) void {
        if (self.owned) win.ole32.CoUninitialize();
    }
};
fn bstr(a: std.mem.Allocator, text: []const u8) !*u16 {
    const value = try n.wide(a, text);
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
        if (self.ptr.Get(n.wideLiteral(name), 0, &value, null, null).failed) return error.WindowsPropertyUnavailable;
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
        if (hr.failed) return error.WindowsEnumerationFailed;
        if (count == 0) return if (@as(u32, @bitCast(hr)) == 1) null else error.WindowsEnumerationTimeout;
        self.count += 1;
        if (self.count > 16384) {
            if (object[0]) |p| _ = p.IUnknown.Release();
            return error.WindowsEnumerationTooLarge;
        }
        return .{ .ptr = object[0] orelse return error.InvalidWindowsResponse };
    }
};
pub const Argument = struct { name: [:0]const u16, value: union(enum) { text: []const u8, uint64: u64, uint32: u32, boolean: bool } };
pub const Connection = struct {
    ptr: *api.IWbemServices,
    failure: *Failure,
    pub fn init(a: std.mem.Allocator, namespace: []const u8, failure: *Failure) !Connection {
        var locator: *api.IWbemLocator = undefined;
        try failure.check(win.ole32.CoCreateInstance(api.CLSID_WbemLocator, null, .{ .INPROC_SERVER = 1 }, api.IID_IWbemLocator, @ptrCast(&locator)));
        defer _ = locator.IUnknown.Release();
        const path = try bstr(a, namespace);
        defer ole.SysFreeString(path);
        var services: ?*api.IWbemServices = null;
        try failure.check(locator.ConnectServer(path, null, null, null, 0x80, null, null, &services));
        const ptr = services orelse return error.InvalidWindowsResponse;
        errdefer _ = ptr.IUnknown.Release();
        try failure.check(win.ole32.CoSetProxyBlanket(&ptr.IUnknown, 10, 0, null, .PKT_PRIVACY, .IMPERSONATE, null, .NONE));
        return .{ .ptr = ptr, .failure = failure };
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
        try self.failure.check(self.ptr.ExecQuery(language, sql, .{ .FLAG_FORWARD_ONLY = 1, .FLAG_RETURN_IMMEDIATELY = 1 }, null, &result));
        const ptr = result orelse return error.InvalidWindowsResponse;
        errdefer _ = ptr.IUnknown.Release();
        try self.failure.check(win.ole32.CoSetProxyBlanket(&ptr.IUnknown, 10, 0, null, .PKT_PRIVACY, .IMPERSONATE, null, .NONE));
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
            try self.failure.check(self.ptr.GetObject(class_name, 0, null, &class, null));
            const definition: Object = .{ .ptr = class orelse return error.WindowsClassUnavailable };
            defer definition.deinit();
            var signature: ?*api.IWbemClassObject = null;
            try self.failure.check(definition.ptr.GetMethod(n.wideLiteral(name), 0, &signature, null));
            defer {
                if (signature) |p| {
                    _ = p.IUnknown.Release();
                }
            }
            try self.failure.check((signature orelse return error.WindowsMethodUnavailable).SpawnInstance(0, &input));
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
                try self.failure.check(input.?.Put(arg.name, 0, &v, 0));
            }
        }
        var output: ?*api.IWbemClassObject = null;
        try self.failure.check(self.ptr.ExecMethod(path, method_name, 0, null, input, &output, null));
        const result: Object = .{ .ptr = output orelse return error.InvalidWindowsResponse };
        errdefer result.deinit();
        const status = try result.number("ReturnValue");
        if (status != 0) {
            self.failure.return_value = status;
            const detail = result.text(a, "ExtendedStatus") catch null;
            if (detail) |s| {
                self.failure.len = @min(s.len, self.failure.detail.len);
                @memcpy(self.failure.detail[0..self.failure.len], s[0..self.failure.len]);
            }
            return error.WindowsStorageMethodFailed;
        }
        return result;
    }
};
