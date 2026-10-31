//! Fixed Windows UEFI variable adapter. No shell, BCD editor, drive letters or
//! caller-selected variable names. Boot ownership is enforced by boot/uefi.zig.
const std = @import("std");
const n = @import("native.zig");
const uefi = @import("../../boot/uefi.zig");
const GLOBAL = n.wideLiteral("{" ++ uefi.GLOBAL_GUID ++ "}");
const PIZZA = n.wideLiteral("{" ++ uefi.PIZZA_GUID ++ "}");
pub const SecureBoot = enum { enabled, disabled, unsupported, unknown };

pub const Firmware = struct {
    writable: bool,
    pub fn open(writable: bool) !Firmware {
        var kind: n.win32.system.system_information.FIRMWARE_TYPE = .Unknown;
        if (n.k.GetFirmwareType(&kind) == 0) return error.FirmwareUnavailable;
        if (kind != .Uefi) return error.UefiRequired;
        if (!@import("session/security.zig").elevated()) return error.AdministratorRequired;
        return .{ .writable = writable };
    }
    pub fn variables(self: *Firmware) uefi.Variables {
        return .{ .context = self, .read = read, .write = write };
    }
    fn name(key: uefi.Variable, buffer: *[9:0]u16) [:0]const u16 {
        return switch (key) {
            .order => n.wideLiteral("BootOrder"),
            .next => n.wideLiteral("BootNext"),
            .current => n.wideLiteral("BootCurrent"),
            .pizza_session => n.wideLiteral("PizzaSession"),
            .boot => |slot| blk: {
                const hex = "0123456789ABCDEF";
                @memcpy(buffer[0..4], n.wideLiteral("Boot"));
                for (0..4) |i| buffer[4 + i] = hex[@as(u4, @truncate(slot >> @intCast(12 - i * 4)))];
                buffer[8] = 0;
                break :blk buffer[0..8 :0];
            },
        };
    }
    fn namespace(key: uefi.Variable) [:0]const u16 {
        return if (key == .pizza_session) PIZZA else GLOBAL;
    }
    fn failure(code: n.f.WIN32_ERROR) anyerror {
        return switch (code) {
            .ERROR_INVALID_FUNCTION, .ERROR_NOT_SUPPORTED => error.UefiRequired,
            .ERROR_ACCESS_DENIED, .ERROR_PRIVILEGE_NOT_HELD => error.FirmwareWriteDenied,
            .ERROR_INSUFFICIENT_BUFFER, .ERROR_MORE_DATA => error.FirmwareVariableTooLarge,
            .ERROR_DISK_FULL, .ERROR_NOT_ENOUGH_MEMORY => error.FirmwareStorageFull,
            else => error.FirmwareAccessFailed,
        };
    }
    fn value(a: std.mem.Allocator, variable: [:0]const u16, vendor: [:0]const u16) !?[]const u8 {
        const buffer = try a.alloc(u8, 65536);
        defer a.free(buffer);
        var attributes: u32 = 0;
        n.k.SetLastError(.NO_ERROR);
        const size = n.k.GetFirmwareEnvironmentVariableExW(variable, vendor, buffer.ptr, @intCast(buffer.len), &attributes);
        if (size == 0) {
            const code = n.k.GetLastError();
            if (code == .ERROR_ENVVAR_NOT_FOUND or code == .ERROR_FILE_NOT_FOUND) return null;
            return failure(code);
        }
        if (size > buffer.len) return error.InvalidFirmwareVariable;
        try validateAttributes(attributes);
        return try a.dupe(u8, buffer[0..size]);
    }
    fn read(_: *anyopaque, a: std.mem.Allocator, _: std.Io, key: uefi.Variable) !?[]const u8 {
        var privilege = try n.Privilege.enable(.firmware);
        defer privilege.deinit();
        var buffer: [9:0]u16 = undefined;
        return value(a, name(key, &buffer), namespace(key));
    }
    fn write(ctx: *anyopaque, _: std.Io, key: uefi.Variable, bytes: ?[]const u8) !void {
        const self: *Firmware = @ptrCast(@alignCast(ctx));
        if (key == .current) return error.ReadOnlyFirmwareVariable;
        if (!self.writable) return error.FirmwareReadOnly;
        if (bytes) |v| {
            if (v.len == 0 or v.len > 65536) return error.InvalidFirmwareVariable;
        }
        var privilege = try n.Privilege.enable(.firmware);
        defer privilege.deinit();
        var buffer: [9:0]u16 = undefined;
        const variable = name(key, &buffer);
        // Boot lease variables must use the ordinary NV/BS/RT attributes. Never
        // delete/recreate a foreign authenticated variable to bypass its policy.
        var probe: [65536]u8 = undefined;
        var attributes: u32 = 0;
        const size = n.k.GetFirmwareEnvironmentVariableExW(variable, namespace(key), &probe, probe.len, &attributes);
        if (size != 0) {
            if (attributes != 7) return error.UnsupportedFirmwareVariableAttributes;
        } else {
            const code = n.k.GetLastError();
            if (code != .ERROR_ENVVAR_NOT_FOUND and code != .ERROR_FILE_NOT_FOUND) return failure(code);
            if (bytes == null) return;
        }
        const data = if (bytes) |v| v.ptr else null;
        const size_out: u32 = if (bytes) |v| @intCast(v.len) else 0;
        if (n.k.SetFirmwareEnvironmentVariableExW(variable, namespace(key), @constCast(data), size_out, 7) == 0) return failure(n.k.GetLastError());
    }
    pub fn secureBoot(_: *Firmware, a: std.mem.Allocator) !SecureBoot {
        var privilege = try n.Privilege.enable(.firmware);
        defer privilege.deinit();
        return secureBootState(try value(a, n.wideLiteral("SecureBoot"), GLOBAL), try value(a, n.wideLiteral("SetupMode"), GLOBAL));
    }
};
/// Non-Secure-Boot UEFI implementations omit these variables. Missing values
/// are distinct from access failures (which value() propagates) or malformed
/// and contradictory firmware state. No policy variables are changed.
fn secureBootState(secure_value: ?[]const u8, setup_value: ?[]const u8) SecureBoot {
    if (secure_value == null and setup_value == null) return .unsupported;
    const secure = secure_value orelse return .unknown;
    const setup = setup_value orelse return .unknown;
    if (secure.len != 1 or setup.len != 1 or secure[0] > 1 or setup[0] > 1 or (secure[0] == 1 and setup[0] == 1)) return .unknown;
    return if (secure[0] == 1) .enabled else .disabled;
}

test "Secure Boot absence differs from malformed or contradictory firmware state" {
    try std.testing.expectEqual(.unsupported, secureBootState(null, null));
    try std.testing.expectEqual(.disabled, secureBootState(&.{0}, &.{1}));
    try std.testing.expectEqual(.enabled, secureBootState(&.{1}, &.{0}));
    try std.testing.expectEqual(.unknown, secureBootState(&.{1}, &.{1}));
    try std.testing.expectEqual(.unknown, secureBootState(&.{0}, null));
    try std.testing.expectEqual(.unknown, secureBootState(null, &.{0}));
    try std.testing.expectEqual(.unknown, secureBootState(&.{2}, &.{0}));
}
fn validateAttributes(attributes: u32) !void {
    if (attributes & 6 != 6 or attributes & ~@as(u32, 7) != 0) return error.UnsupportedFirmwareVariableAttributes;
}

/// The coordinator calls this only after the durable handoff and boot lease
/// have been read back. Give applications time to close without forcing them.
pub fn reboot() !void {
    var privilege = try n.Privilege.enable(.shutdown);
    defer privilege.deinit();
    if (n.win32.advapi32.InitiateSystemShutdownExW(null, null, 30, 0, 1, @bitCast(@as(u32, 0x80040000))) == 0) return error.RebootRequestFailed;
}

test "firmware keys cannot escape fixed names or namespaces" {
    var buffer: [9:0]u16 = undefined;
    try std.testing.expectEqualSlices(u16, n.wideLiteral("Boot00AF"), Firmware.name(.{ .boot = 0xaf }, &buffer));
    try std.testing.expectEqualSlices(u16, n.wideLiteral("BootFFFF"), Firmware.name(.{ .boot = 0xffff }, &buffer));
    try std.testing.expectEqualSlices(u16, n.wideLiteral("BootOrder"), Firmware.name(.order, &buffer));
    try std.testing.expectEqualSlices(u16, PIZZA, Firmware.namespace(.pizza_session));
    try std.testing.expectEqualSlices(u16, GLOBAL, Firmware.namespace(.next));
    try validateAttributes(6);
    try validateAttributes(7);
    try std.testing.expectError(error.UnsupportedFirmwareVariableAttributes, validateAttributes(0x27));
    try std.testing.expectError(error.UnsupportedFirmwareVariableAttributes, validateAttributes(2));
}

test "read-only firmware rejects writes before calling Windows" {
    var firmware: Firmware = .{ .writable = false };
    try std.testing.expectError(error.FirmwareReadOnly, firmware.variables().set(std.testing.allocator, std.testing.io, .next, &.{ 1, 0 }));
    const reboot_entry = reboot;
    std.mem.doNotOptimizeAway(&reboot_entry);
}

test "Windows UEFI boot inventory is read-only and uses scoped privileges" {
    var firmware = Firmware.open(false) catch |err| switch (err) {
        error.AdministratorRequired, error.UefiRequired => return error.SkipZigTest,
        else => return err,
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const order = try firmware.variables().get(arena.allocator(), std.testing.io, .order) orelse return error.MissingBootOrder;
    try std.testing.expect(order.len != 0 and order.len % 2 == 0);
    _ = try firmware.secureBoot(arena.allocator());
}
