//! Native imports are compiled on Windows; pure policy tests also run on Linux.
test {
    _ = @import("../core/platform/windows/firmware.zig");
    _ = @import("../core/platform/windows/esp.zig");
    _ = @import("../core/platform/windows/policy.zig");
    _ = @import("../core/platform/windows/session.zig");
}
const std = @import("std");

test "Windows VPD descriptor may end with a bounded nonzero NextOffset" {
    const hex = "100000004c000000020000000200000000000000130024000000000050495a5a412d464c4f572d323032363130323800010000000300000008001c0000000000500140000000000000000000";
    var bytes: [76]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = try std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16);
    const value = (try @import("../core/platform/windows/native.zig").portableWwid(std.testing.allocator, &bytes)).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("naa.5001400000000000", value);
    std.mem.writeInt(u16, bytes[58..60], 29, .little);
    try std.testing.expectError(error.InvalidStorageIdentifiers, @import("../core/platform/windows/native.zig").portableWwid(std.testing.allocator, &bytes));
}
const n = @import("../core/platform/windows/native.zig");
const security = @import("../core/platform/windows/session/security.zig");
const transport = @import("../core/platform/windows/session/transport.zig");

test "portable storage IDs ignore port identifiers and reject malformed descriptor offsets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A device EUI-64, a device NAA-5 and a target-port NAA. Linux prefers the
    // device NAA; the port must never become a physical disk's stable identity.
    var bytes: [84]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 16, .little);
    std.mem.writeInt(u32, bytes[4..8], bytes.len, .little);
    std.mem.writeInt(u32, bytes[8..12], 3, .little);
    for (0..3) |i| {
        const entry = bytes[12 + i * 24 ..];
        std.mem.writeInt(u32, entry[0..4], 1, .little);
        std.mem.writeInt(u32, entry[4..8], if (i == 0) 2 else 3, .little);
        std.mem.writeInt(u16, entry[8..10], 8, .little);
        std.mem.writeInt(u16, entry[10..12], if (i == 2) 0 else 24, .little);
        std.mem.writeInt(u32, entry[12..16], if (i == 2) 1 else 0, .little);
        @memset(entry[16..24], @intCast(i + 1));
        entry[16] = 0x50;
    }
    try std.testing.expectEqualStrings("naa.5002020202020202", (try n.portableWwid(a, &bytes)).?);
    var invalid = bytes;
    std.mem.writeInt(u16, invalid[22..24], 4, .little);
    try std.testing.expectError(error.InvalidStorageIdentifiers, n.portableWwid(a, &invalid));
    invalid = bytes;
    std.mem.writeInt(u16, invalid[44..46], 65535, .little);
    try std.testing.expectError(error.InvalidStorageIdentifiers, n.portableWwid(a, &invalid));
    invalid = bytes;
    std.mem.writeInt(u32, invalid[72..76], 0, .little); // another device NAA
    try std.testing.expectError(error.AmbiguousStorageIdentity, n.portableWwid(a, &invalid));
}

test "WMI inventory joins geometry without changing any disk" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const snapshot = try @import("../core/platform/windows/inventory.zig").query(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(.windows, snapshot.platform);
    try std.testing.expectEqual(@as(usize, 64), snapshot.snapshot_id.len);
    for (snapshot.disks) |disk| for (disk.partitions) |part| {
        _ = try @import("proto").byteCount(part.offset);
        _ = try @import("proto").byteCount(part.length);
        if (part.encryption != .none or part.protected) for (part.capabilities) |cap| {
            try std.testing.expect(cap.support != .available);
        };
    };
}
test "pipe framing handles fragmentation and rejects oversized frames" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try n.wide(a, try a.print("\\\\.\\pipe\\Pizza-test-{d}-{d}", .{ n.k.GetCurrentProcessId(), n.k.GetTickCount64() }));
    const pipe = n.valid(n.k.CreateNamedPipeW(path, n.PIPE_SERVER_FLAGS, .{ .NOWAIT = 1, .REJECT_REMOTE_CLIENTS = 1 }, 1, 128, 128, 0, null)) orelse return error.PipeUnavailable;
    defer n.close(pipe);
    const h = n.valid(n.k.CreateFileW(path, @bitCast(n.GENERIC_READ | n.GENERIC_WRITE), .{}, null, .OPEN_EXISTING, n.fs.SECURITY_SQOS_PRESENT, null)) orelse return error.PipeUnavailable;
    defer n.close(h);
    defer _ = n.k.DisconnectNamedPipe(pipe);
    _ = n.k.ConnectNamedPipe(pipe, null);
    var mode: n.win32.system.pipes.NAMED_PIPE_MODE = .{ .NOWAIT = 1 };
    try std.testing.expect(n.k.SetNamedPipeHandleState(h, &mode, null, null) != 0);
    const Fragmented = struct {
        fn write(handle: n.f.HANDLE) void {
            transport.writeAll(handle, &.{ 5, 0 }, transport.deadline()) catch return;
            n.k.Sleep(20);
            transport.writeAll(handle, &.{ 0, 0, 'h' }, transport.deadline()) catch return;
            n.k.Sleep(20);
            transport.writeAll(handle, "ello", transport.deadline()) catch {};
        }
    };
    const writer = try std.Thread.spawn(.{}, Fragmented.write, .{h});
    defer writer.join();
    try std.testing.expectEqualStrings("hello", try transport.receive(a, pipe, 8));
    try transport.writeAll(h, &.{ 9, 0, 0, 0 }, transport.deadline());
    try std.testing.expectError(error.InvalidPipeFrame, transport.receive(a, pipe, 8));
    try std.testing.expectError(error.InvalidPipeFrame, transport.send(h, "oversized", 8));
}
test "kernel peer credentials distinguish processes and exact executable identity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const owner = try security.identity(a, n.k.GetCurrentProcess());
    try security.peer(a, n.k.GetCurrentProcessId(), owner, owner.elevated);
    var other = owner;
    other.session +%= 1;
    try std.testing.expectError(error.UnauthorizedPeer, security.peer(a, n.k.GetCurrentProcessId(), other, false));
    try std.testing.expectError(error.PeerUnavailable, security.peer(a, 0, owner, false));
}
test "durable records are replaced atomically and reject public files" {
    if (!security.elevated()) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [32768]u8 = undefined;
    const length = try temp.dir.realPath(std.testing.io, &buffer);
    var store: @import("../core/platform/windows/session/store.zig") = .{ .path = buffer[0..length] };
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try store.persist(id, "{\"prepared\":1}");
    try std.testing.expectEqualStrings("{\"prepared\":1}", (try store.read(a, id)).?);
    try store.persist(id, "{\"completed\":1}");
    try std.testing.expectEqualStrings("{\"completed\":1}", (try store.read(a, id)).?);
    try std.testing.expectEqualStrings(id, (try store.latest(a)).?);
    try std.testing.expectError(error.InvalidSession, store.persist("../escape", "{}"));
    const public_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = public_id ++ ".json", .data = "{}" });
    try std.testing.expect((try store.read(a, public_id)) == null);
}
