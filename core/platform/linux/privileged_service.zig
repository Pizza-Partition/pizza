//! Linux session boundary: authentication, one execution worker and its durable store.
const Session = @This();
const std = @import("std");
const libc = @import("libc");
const client = @import("ipc/client.zig");
const Worker = @import("../../execution/worker.zig");
const Store = @import("ipc/store.zig");
const transport = @import("ipc/transport.zig");
const validId = Worker.validId;
pub const Handler = *const fn (?*anyopaque, std.mem.Allocator, []const u8) []const u8;
worker: Worker = .{},
store: Store = .{},

pub fn isPrivileged(_: *const Session) bool {
    return libc.geteuid() == 0;
}
pub fn readiness(_: *const Session) client.Readiness {
    return client.readiness();
}
pub fn call(_: *Session, a: std.mem.Allocator, request: []const u8) !?[]const u8 {
    return client.call(a, request);
}
pub fn elevate(_: *Session, a: std.mem.Allocator, request: []const u8) !?[]const u8 {
    return client.elevate(a, request);
}
const Server = struct {
    token: [64]u8,
    context: ?*anyopaque,
    handler: Handler,
    worker: *Worker,
    clients: std.atomic.Value(u32) = .init(0),

    fn serveClient(self: *Server, fd: c_int) void {
        defer _ = self.clients.fetchSub(1, .release);
        defer _ = libc.close(fd);
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const bytes = transport.readBounded(a, fd, transport.MAX_REQUEST + 65) catch return;
        if (bytes.len < 66 or bytes[64] != '\n' or !std.mem.eql(u8, bytes[0..64], &self.token)) return;
        _ = transport.sendAll(fd, self.handler(self.context, a, bytes[65..]));
    }
};
pub fn serve(self: *Session, io: std.Io, context: ?*anyopaque, handler: Handler) !u8 {
    const worker = &self.worker;
    const store = &self.store;
    if (libc.geteuid() != 0) return 1;
    _ = libc.setenv("PATH", "/usr/sbin:/usr/bin:/sbin:/bin", 1);
    _ = libc.signal(libc.SIGPIPE, libc.SIG_IGN);
    var user = libc.getenv("PKEXEC_UID");
    if (user == null or user[0] == 0) user = libc.getenv("SUDO_UID");
    if (user == null) return 1;
    const owner = std.fmt.parseInt(libc.uid_t, std.mem.span(user), 10) catch return 1;
    if (owner == 0) return 1;
    var input: [65]u8 = undefined;
    if (!transport.readExact(0, &input) or input[64] != '\n' or !validId(input[0..64])) return 1;
    store.owner = owner;
    var server: Server = .{ .token = input[0..64].*, .worker = worker, .context = context, .handler = handler };
    var dir_buffer: [128]u8 = undefined;
    const dir = try std.mem.printSentinel(&dir_buffer, "/run/pizza/{d}", .{owner}, 0);
    if (!Store.directory("/run/pizza", 0o711) or !Store.directory(dir, 0o711)) return 1;
    var lock_buffer: [160]u8 = undefined;
    const lease = libc.open(try std.mem.printSentinel(&lock_buffer, "{s}/worker.lock", .{dir}, 0), libc.O_CREAT | libc.O_RDWR | libc.O_CLOEXEC | libc.O_NOFOLLOW, @as(libc.mode_t, 0o600));
    if (lease < 0) return 1;
    defer _ = libc.close(lease);
    if (libc.flock(lease, libc.LOCK_EX | libc.LOCK_NB) != 0) return 1;
    const fd = libc.socket(libc.AF_UNIX, libc.SOCK_STREAM | libc.SOCK_CLOEXEC, 0);
    if (fd < 0) return 1;
    defer _ = libc.close(fd);
    var sock_buffer: [108]u8 = undefined;
    const sock = try std.mem.printSentinel(&sock_buffer, "{s}/control.sock", .{dir}, 0);
    _ = libc.unlink(sock);
    var addr = try transport.address(sock);
    if (libc.bind(fd, .{ .__sockaddr_un__ = &addr }, @sizeOf(@TypeOf(addr))) != 0 or libc.chown(sock, owner, 0) != 0 or libc.chmod(sock, 0o600) != 0 or libc.listen(fd, 8) != 0) return 1;
    defer _ = libc.unlink(sock);
    if (!transport.writeAll(1, "READY\n")) return 1;
    defer worker.wait(io);
    while (true) {
        var poll: libc.struct_pollfd = .{ .fd = fd, .events = libc.POLLIN, .revents = 0 };
        const ready = libc.poll(&poll, 1, 300_000);
        if (ready == 0 and server.clients.load(.acquire) == 0 and !worker.busy()) break;
        if (ready <= 0) continue;
        const connection = libc.accept4(fd, .{ .__sockaddr__ = null }, null, libc.SOCK_CLOEXEC);
        if (connection < 0) continue;
        if (!transport.peerIs(connection, owner) or server.clients.load(.acquire) >= 16) {
            _ = libc.close(connection);
            continue;
        }
        transport.deadline(connection) catch |err| {
            std.log.err("Cannot bound session connection I/O: {t}", .{err});
            _ = libc.close(connection);
            continue;
        };
        _ = server.clients.fetchAdd(1, .acq_rel);
        if (std.Thread.spawn(.{}, Server.serveClient, .{ &server, connection })) |thread| thread.detach() else |_| {
            _ = server.clients.fetchSub(1, .release);
            _ = libc.close(connection);
        }
    }
    return 0;
}
test "IPC authenticates the peer and nonce before dispatching a complete request" {
    const Fixture = struct {
        fn handle(context: ?*anyopaque, _: std.mem.Allocator, request: []const u8) []const u8 {
            const calls: *usize = @ptrCast(@alignCast(context.?));
            calls.* += 1;
            return request;
        }
    };
    const a = std.testing.allocator;
    var calls: usize = 0;
    var worker: Worker = .{};
    var server: Server = .{ .token = @splat('a'), .context = &calls, .handler = Fixture.handle, .worker = &worker };
    const prefix = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const cases = [_][]const u8{
        prefix ++ "\n{\"action\":\"status\"}",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n{}",
        prefix ++ "\n",
    };
    for (cases, 0..) |request, index| {
        var pair: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), libc.socketpair(libc.AF_UNIX, libc.SOCK_STREAM | libc.SOCK_CLOEXEC, 0, &pair));
        defer _ = libc.close(pair[0]);
        try std.testing.expect(transport.peerIs(pair[0], libc.geteuid()));
        try std.testing.expect(!transport.peerIs(pair[0], if (libc.geteuid() == 0) 1 else 0));
        _ = server.clients.fetchAdd(1, .acq_rel);
        const thread = try std.Thread.spawn(.{}, Server.serveClient, .{ &server, pair[1] });
        defer thread.join();
        try std.testing.expect(transport.sendAll(pair[0], request));
        try std.testing.expectEqual(@as(c_int, 0), libc.shutdown(pair[0], libc.SHUT_WR));
        const reply = try transport.readBounded(a, pair[0], 256);
        defer a.free(reply);
        try std.testing.expectEqualStrings(if (index == 0) "{\"action\":\"status\"}" else "", reply);
    }
    try std.testing.expectEqual(@as(usize, 1), calls);
}
