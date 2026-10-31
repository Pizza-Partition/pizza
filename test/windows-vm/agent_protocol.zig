//! Bounded, allowlisted commands for an isolated VM's second serial port.
const std = @import("std");

pub const Request = struct {
    id: []const u8,
    action: enum { install, probe, servicing, freeze, restart, native, setup, plan, prepare, reboot, verify, collect, shutdown },
    work: []const u8,
    serial: []const u8,
    wwn: []const u8,
    case: @import("vm_common").cases.Case,
    pub fn validate(r: Request) !void {
        if (!std.mem.startsWith(u8, r.work, "C:\\Pizza-E2E-") or r.work.len != 25)
            return error.InvalidWorkDirectory;
        const token = r.work[13..];
        for (token) |ch| if (!std.ascii.isHex(ch)) return error.InvalidWorkDirectory;
        if (r.id.len == 0 or r.id.len > 80) return error.InvalidRequestId;
        for (r.id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return error.InvalidRequestId;
        if (r.serial.len != 19 or
            !std.mem.startsWith(u8, r.serial, "PZ-E2E-") or
            !std.mem.eql(u8, r.serial[7..], token))
            return error.InvalidTarget;
        if (r.wwn.len != 16 or
            !std.mem.startsWith(u8, r.wwn, "5001") or
            !std.mem.eql(u8, r.wwn[4..], token))
            return error.InvalidTarget;
    }
};

pub const Response = struct {
    id: []const u8,
    ok: bool,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};
pub const Responses = struct {
    cursor: usize = 0,
    pub fn next(reader: *Responses, allocator: std.mem.Allocator, bytes: []const u8, id: []const u8) !?Response {
        while (std.mem.indexOfScalarPos(u8, bytes, reader.cursor, '\n')) |end| {
            const line = std.mem.trim(u8, bytes[reader.cursor..end], "\r");
            reader.cursor = end + 1;
            if (!std.mem.startsWith(u8, line, "PZ_AGENT:")) continue;
            const response = try std.json.parseFromSliceLeaky(Response, allocator, line[9..], .{});
            if (std.mem.eql(u8, response.id, id)) return response;
        }
        return null;
    }
};
pub const ServicingStatus = struct { reboot_pending: bool, installer_running: bool, update_services_running: bool = false, updates_disabled: bool, uptime_ms: u64 };

test "response output survives chunk boundaries and a trailing partial heartbeat" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expected = "PZ_SERVICING:{\"pending\":false}\nfirst-file\n";
    const wrong = try std.json.Stringify.valueAlloc(a, Response{ .id = "old", .ok = true, .stdout = "stale" }, .{});
    const target = try std.json.Stringify.valueAlloc(a, Response{ .id = "current", .ok = true, .stdout = expected }, .{});
    const wire = try a.print("PZ_AGENT_READY\nPZ_AGENT:{s}\nPZ_AGENT:{s}\nPZ_AGENT_REA", .{ wrong, target });
    var reader: Responses = .{};
    try std.testing.expect((try reader.next(a, wire[0 .. wire.len - 18], "current")) == null);
    const response = (try reader.next(a, wire, "current")).?;
    try std.testing.expectEqualStrings(expected, response.stdout);
    try std.testing.expect(std.mem.endsWith(u8, wire[reader.cursor..], "PZ_AGENT_REA"));
    try std.testing.expect((try reader.next(a, wire, "current")) == null);
}

test "serial agent refuses traversal, shell arguments and inconsistent target tokens" {
    var r: Request = .{ .id = "PZ_123_1", .action = .probe, .work = "C:\\Pizza-E2E-001122aabbcc", .serial = "PZ-E2E-001122aabbcc", .wwn = "5001001122aabbcc", .case = .accept };
    try r.validate();
    r.work = "C:\\Pizza-E2E-..\\Windows";
    try std.testing.expectError(error.InvalidWorkDirectory, r.validate());
    r.work = "C:\\Pizza-E2E-001122aabbcc";
    r.id = "x & shutdown";
    try std.testing.expectError(error.InvalidRequestId, r.validate());
    r.id = "ok";
    r.wwn = "5001001122aabbcd";
    try std.testing.expectError(error.InvalidTarget, r.validate());
}
