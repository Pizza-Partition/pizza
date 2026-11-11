//! Fixed Windows UEFI variable adapter. No shell, BCD editor, drive letters or
//! caller-selected variable names. Boot ownership is enforced by boot/uefi.zig.
const std = @import("std");
const native = @import("native.zig");
const uefi = @import("../../boot/uefi.zig");
const GLOBAL = native.wideLiteral("{" ++ uefi.GLOBAL_GUID ++ "}");
const PIZZA = native.wideLiteral("{" ++ uefi.PIZZA_GUID ++ "}");

/// A firmware transaction owns a temporary thread token. Open, use and close
/// it on the same thread; close before entering another privilege scope.
pub const Uefi = struct {
    writable: bool,
    privilege: native.Privilege,
    pub fn open(_: std.Io, writable: bool) !Uefi {
        var kind: native.win32.system.system_information.FIRMWARE_TYPE = .Unknown;
        if (native.kernel32.GetFirmwareType(&kind) == 0) return error.FirmwareUnavailable;
        if (kind != .Uefi) return error.UefiRequired;
        if (!@import("ipc/security.zig").elevated()) return error.AdministratorRequired;
        return .{ .writable = writable, .privilege = try native.Privilege.enable(.uefi) };
    }

    pub fn close(self: *Uefi, _: std.Io) void {
        self.privilege.deinit();
        self.* = undefined;
    }

    const vtable: uefi.Variables.VTable = .{
        .read = read,
        .write = write,
    };

    pub fn variables(self: *Uefi) uefi.Variables {
        return .{ .context = self, .vtable = &vtable };
    }

    fn name(key: uefi.Variable, buffer: *[9:0]u16) [:0]const u16 {
        return switch (key) {
            .order => native.wideLiteral("BootOrder"),
            .next => native.wideLiteral("BootNext"),
            .current => native.wideLiteral("BootCurrent"),
            .pizza_session => native.wideLiteral("PizzaSession"),
            .boot => |slot| blk: {
                const hex = "0123456789ABCDEF";
                @memcpy(buffer[0..4], native.wideLiteral("Boot"));
                for (0..4) |i| buffer[4 + i] = hex[@as(u4, @truncate(slot >> @intCast(12 - i * 4)))];
                buffer[8] = 0;
                break :blk buffer[0..8 :0];
            },
        };
    }

    fn namespace(key: uefi.Variable) [:0]const u16 {
        return if (key == .pizza_session) PIZZA else GLOBAL;
    }

    fn failure(code: native.foundation.WIN32_ERROR) anyerror {
        return switch (code) {
            .ERROR_INVALID_FUNCTION, .ERROR_NOT_SUPPORTED => error.UefiRequired,
            .ERROR_ACCESS_DENIED, .ERROR_PRIVILEGE_NOT_HELD => error.FirmwareWriteDenied,
            .ERROR_INSUFFICIENT_BUFFER, .ERROR_MORE_DATA => error.FirmwareVariableTooLarge,
            .ERROR_DISK_FULL, .ERROR_NOT_ENOUGH_MEMORY => error.FirmwareStorageFull,
            else => error.FirmwareAccessFailed,
        };
    }

    // No required-size output is available from this API. Start small enough
    // for scalar variables and modest boot entries; double only on size errors.
    const INITIAL_VARIABLE_BYTES = 512;
    const MAX_VARIABLE_BYTES = 65536;

    fn query(comptime api: type, a: std.mem.Allocator, variable: [:0]const u16, vendor: [:0]const u16, buffer: *std.ArrayList(u8)) !?u32 {
        var capacity: usize = INITIAL_VARIABLE_BYTES;
        while (true) {
            try buffer.ensureTotalCapacityPrecise(a, capacity);
            var attributes: u32 = 0;
            api.SetLastError(.NO_ERROR);
            const size = api.GetFirmwareEnvironmentVariableExW(variable, vendor, buffer.items.ptr, @intCast(capacity), &attributes);
            if (size != 0) {
                if (size > capacity) return error.InvalidFirmwareVariable;
                buffer.items.len = size;
                return attributes;
            }
            const code = api.GetLastError();
            switch (code) {
                .ERROR_ENVVAR_NOT_FOUND, .ERROR_FILE_NOT_FOUND => return null,
                .ERROR_INSUFFICIENT_BUFFER, .ERROR_MORE_DATA => {
                    if (capacity == MAX_VARIABLE_BYTES) return error.FirmwareVariableTooLarge;
                    capacity *= 2;
                },
                else => return failure(code),
            }
        }
    }

    fn value(a: std.mem.Allocator, variable: [:0]const u16, vendor: [:0]const u16) !?[]const u8 {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(a);
        const attributes = try query(native.kernel32, a, variable, vendor, &buffer) orelse return null;
        try validateAttributes(attributes);
        return try buffer.toOwnedSlice(a);
    }

    fn read(_: *anyopaque, a: std.mem.Allocator, _: std.Io, key: uefi.Variable) !?[]const u8 {
        var buffer: [9:0]u16 = undefined;
        return value(a, name(key, &buffer), namespace(key));
    }

    fn write(ctx: *anyopaque, a: std.mem.Allocator, _: std.Io, key: uefi.Variable, bytes: ?[]const u8) !void {
        const self: *Uefi = @ptrCast(@alignCast(ctx));
        if (key == .current) return error.ReadOnlyFirmwareVariable;
        if (!self.writable) return error.FirmwareReadOnly;
        if (bytes) |b| if (b.len == 0 or b.len > MAX_VARIABLE_BYTES) return error.InvalidFirmwareVariable;

        var buffer: [9:0]u16 = undefined;
        const variable = name(key, &buffer);
        // Boot lease variables must use the ordinary NV/BS/RT attributes. Never
        // delete/recreate a foreign authenticated variable to bypass its policy.
        var probe: std.ArrayList(u8) = .empty;
        defer probe.deinit(a);
        if (try query(native.kernel32, a, variable, namespace(key), &probe)) |attributes| {
            if (attributes != 7) return error.UnsupportedFirmwareVariableAttributes;
        } else if (bytes == null) return;
        const data, const size_out = if (bytes) |b| .{ b.ptr, @as(u32, @intCast(b.len)) } else .{ null, 0 };
        if (native.kernel32.SetFirmwareEnvironmentVariableExW(variable, namespace(key), @constCast(data), size_out, 7) == 0)
            return failure(native.kernel32.GetLastError());
    }

    pub fn secureBoot(_: *Uefi, a: std.mem.Allocator) !uefi.SecureBoot {
        return uefi.secureBootState(try value(a, native.wideLiteral("SecureBoot"), GLOBAL), try value(a, native.wideLiteral("SetupMode"), GLOBAL));
    }
};

fn validateAttributes(attributes: u32) !void {
    if (attributes & 6 != 6 or attributes & ~@as(u32, 7) != 0) return error.UnsupportedFirmwareVariableAttributes;
}

test "firmware keys cannot escape fixed names or namespaces" {
    var buffer: [9:0]u16 = undefined;
    try std.testing.expectEqualSlices(u16, native.wideLiteral("Boot00AF"), Uefi.name(.{ .boot = 0xaf }, &buffer));
    try std.testing.expectEqualSlices(u16, native.wideLiteral("BootFFFF"), Uefi.name(.{ .boot = 0xffff }, &buffer));
    try std.testing.expectEqualSlices(u16, native.wideLiteral("BootOrder"), Uefi.name(.order, &buffer));
    try std.testing.expectEqualSlices(u16, PIZZA, Uefi.namespace(.pizza_session));
    try std.testing.expectEqualSlices(u16, GLOBAL, Uefi.namespace(.next));
    try validateAttributes(6);
    try validateAttributes(7);
    try std.testing.expectError(error.UnsupportedFirmwareVariableAttributes, validateAttributes(0x27));
    try std.testing.expectError(error.UnsupportedFirmwareVariableAttributes, validateAttributes(2));
}

test "read-only firmware rejects writes before calling Windows" {
    var firmware: Uefi = .{ .writable = false, .privilege = undefined };
    try std.testing.expectError(error.FirmwareReadOnly, firmware.variables().set(std.testing.allocator, std.testing.io, .next, &.{ 1, 0 }));
}

test "Windows UEFI boot inventory is read-only and uses scoped privileges" {
    var firmware = Uefi.open(std.testing.io, false) catch |err| switch (err) {
        error.AdministratorRequired, error.UefiRequired => return error.SkipZigTest,
        else => return err,
    };
    defer firmware.close(std.testing.io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const order = try firmware.variables().get(arena.allocator(), std.testing.io, .order) orelse return error.MissingBootOrder;
    try std.testing.expect(order.len != 0 and order.len % 2 == 0);
    _ = try firmware.secureBoot(arena.allocator());
}

const QueryTestApi = struct {
    var needed: usize = 0;
    var last_error: native.foundation.WIN32_ERROR = .NO_ERROR;
    var forced_error: ?native.foundation.WIN32_ERROR = null;
    var capacities: [8]u32 = undefined;
    var calls: usize = 0;

    fn reset(size: usize, code: ?native.foundation.WIN32_ERROR) void {
        needed = size;
        forced_error = code;
        calls = 0;
        last_error = .NO_ERROR;
    }

    pub fn SetLastError(code: native.foundation.WIN32_ERROR) void {
        last_error = code;
    }

    pub fn GetLastError() native.foundation.WIN32_ERROR {
        return last_error;
    }

    pub fn GetFirmwareEnvironmentVariableExW(_: [:0]const u16, _: [:0]const u16, buffer: [*]u8, capacity: u32, attributes: *u32) u32 {
        capacities[calls] = capacity;
        calls += 1;
        if (forced_error) |code| {
            last_error = code;
            return 0;
        }
        if (capacity < needed) {
            last_error = if (calls % 2 == 0) .ERROR_MORE_DATA else .ERROR_INSUFFICIENT_BUFFER;
            return 0;
        }
        @memset(buffer[0..needed], 0xa5);
        attributes.* = 7;
        return @intCast(needed);
    }
};

test "UEFI reads grow from 512 bytes through the exact 64 KiB limit" {
    const a = std.testing.allocator;
    for ([_]usize{ 1, 512, 513, 4096, 65536 }) |size| {
        QueryTestApi.reset(size, null);
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(a);
        try std.testing.expectEqual(@as(?u32, 7), try Uefi.query(QueryTestApi, a, native.wideLiteral("BootOrder"), GLOBAL, &buffer));
        try std.testing.expectEqual(size, buffer.items.len);
        try std.testing.expect(std.mem.allEqual(u8, buffer.items, 0xa5));
        var expected_capacity: u32 = 512;
        for (QueryTestApi.capacities[0..QueryTestApi.calls]) |capacity| {
            try std.testing.expectEqual(expected_capacity, capacity);
            expected_capacity *= 2;
        }
        try std.testing.expect(QueryTestApi.capacities[QueryTestApi.calls - 1] >= size);
        if (QueryTestApi.calls > 1) try std.testing.expect(QueryTestApi.capacities[QueryTestApi.calls - 2] < size);
    }
    QueryTestApi.reset(65537, null);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    try std.testing.expectError(error.FirmwareVariableTooLarge, Uefi.query(QueryTestApi, a, native.wideLiteral("BootOrder"), GLOBAL, &buffer));
    try std.testing.expectEqual(@as(usize, 8), QueryTestApi.calls);
    try std.testing.expectEqual(@as(u32, 65536), QueryTestApi.capacities[7]);
}

test "UEFI reads do not retry missing variables or unrelated failures" {
    const a = std.testing.allocator;
    for ([_]native.foundation.WIN32_ERROR{ .ERROR_ENVVAR_NOT_FOUND, .ERROR_FILE_NOT_FOUND, .ERROR_ACCESS_DENIED, .ERROR_NOT_ENOUGH_MEMORY, .ERROR_INVALID_FUNCTION, .NO_ERROR }) |code| {
        QueryTestApi.reset(1, code);
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(a);
        const result = Uefi.query(QueryTestApi, a, native.wideLiteral("BootOrder"), GLOBAL, &buffer);
        switch (code) {
            .ERROR_ENVVAR_NOT_FOUND, .ERROR_FILE_NOT_FOUND => try std.testing.expectEqual(@as(?u32, null), try result),
            .ERROR_ACCESS_DENIED => try std.testing.expectError(error.FirmwareWriteDenied, result),
            .ERROR_NOT_ENOUGH_MEMORY => try std.testing.expectError(error.FirmwareStorageFull, result),
            .ERROR_INVALID_FUNCTION => try std.testing.expectError(error.UefiRequired, result),
            .NO_ERROR => try std.testing.expectError(error.FirmwareAccessFailed, result),
            else => unreachable,
        }
        try std.testing.expectEqual(@as(usize, 1), QueryTestApi.calls);
    }
}

test "UEFI transaction restores the thread token on success and failure" {
    for ([_]bool{ false, true }) |fail| {
        const result: anyerror!void = transaction: {
            var firmware = Uefi.open(std.testing.io, false) catch |err| switch (err) {
                error.AdministratorRequired, error.UefiRequired => return error.SkipZigTest,
                else => return err,
            };
            defer firmware.close(std.testing.io);

            // The token stays active for the whole transaction, rather than
            // being acquired separately by each variable operation.
            var token: ?native.foundation.HANDLE = null;
            if (native.win32.advapi32.OpenThreadToken(native.kernel32.GetCurrentThread(), .{ .QUERY = 1 }, 1, &token) == 0) return error.MissingTransactionToken;
            _ = native.kernel32.CloseHandle(token orelse return error.MissingTransactionToken);
            if (fail) break :transaction error.SimulatedTransactionFailure;
            break :transaction {};
        };
        if (fail) {
            try std.testing.expectError(error.SimulatedTransactionFailure, result);
        } else try result;

        // A later shutdown privilege scope must not see a lingering firmware
        // impersonation token, regardless of how the transaction exited.
        var token: ?native.foundation.HANDLE = null;
        if (native.win32.advapi32.OpenThreadToken(native.kernel32.GetCurrentThread(), .{ .QUERY = 1 }, 1, &token) != 0) {
            if (token) |handle| _ = native.kernel32.CloseHandle(handle);
            return error.LeakedTransactionToken;
        }
        try std.testing.expectEqual(native.foundation.WIN32_ERROR.ERROR_NO_TOKEN, native.kernel32.GetLastError());
    }
}
