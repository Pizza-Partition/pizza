//! libvirt owns QMP and VM lifecycle; the test owns exactly one transient domain.
const std = @import("std");
pub const c = @import("libvirt_c");
pub fn checked(rc: c_int) !void {
    if (rc < 0) return lastError();
}
pub fn lastError() error{LibvirtFailed} {
    if (c.virGetLastError()) |e| if (e.*.message != null) std.debug.print("libvirt: {s}\n", .{e.*.message});
    return error.LibvirtFailed;
}
const Events = struct {
    stopped: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    timer: c_int = -1,
    fn tick(_: c_int, _: ?*anyopaque) callconv(.c) void {}
    fn loop(e: *Events) void {
        while (!e.stopped.load(.acquire)) {
            if (c.virEventRunDefaultImpl() < 0) break;
        }
    }
    fn start() !*Events {
        try checked(c.virEventRegisterDefaultImpl());
        const e = try std.heap.page_allocator.create(Events);
        errdefer std.heap.page_allocator.destroy(e);
        e.* = .{};
        e.timer = c.virEventAddTimeout(50, tick, null, null);
        try checked(e.timer);
        errdefer _ = c.virEventRemoveTimeout(e.timer);
        e.thread = try std.Thread.spawn(.{}, loop, .{e});
        return e;
    }
    fn deinit(e: *Events) void {
        e.stopped.store(true, .release);
        if (e.thread) |thread| thread.join();
        _ = c.virEventRemoveTimeout(e.timer);
        std.heap.page_allocator.destroy(e);
    }
};
pub const Domain = struct {
    connection: c.virConnectPtr,
    domain: c.virDomainPtr = null,
    stream: c.virStreamPtr = null,
    agent_stream: c.virStreamPtr = null,
    a: std.mem.Allocator,
    events: *Events,
    pub fn connect(a: std.mem.Allocator, uri: []const u8) !Domain {
        try checked(c.virInitialize());
        const events = try Events.start();
        errdefer events.deinit();
        const conn = c.virConnectOpen(try a.dupeSentinel(u8, uri, 0)) orelse return lastError();
        return .{ .a = a, .connection = conn, .events = events };
    }
    pub fn deinit(d: *Domain) void {
        d.stop() catch {};
        _ = c.virConnectClose(d.connection);
        d.events.deinit();
    }
    pub fn start(d: *Domain, xml: []const u8) !void {
        if (d.domain != null) return error.DomainAlreadyOwned;
        d.domain = c.virDomainCreateXML(d.connection, try d.a.dupeSentinel(u8, xml, 0), c.VIR_DOMAIN_START_AUTODESTROY) orelse return lastError();
        errdefer d.stop() catch {};
        d.stream = c.virStreamNew(d.connection, c.VIR_STREAM_NONBLOCK) orelse return lastError();
        try checked(c.virDomainOpenConsole(d.domain, null, d.stream, c.VIR_DOMAIN_CONSOLE_FORCE));
        d.agent_stream = c.virStreamNew(d.connection, c.VIR_STREAM_NONBLOCK) orelse return lastError();
        try checked(c.virDomainOpenConsole(d.domain, "serial1", d.agent_stream, c.VIR_DOMAIN_CONSOLE_FORCE));
    }
    pub fn stop(d: *Domain) !void {
        if (d.agent_stream) |s| {
            _ = c.virStreamAbort(s);
            _ = c.virStreamFree(s);
            d.agent_stream = null;
        }
        if (d.stream) |s| {
            _ = c.virStreamAbort(s);
            _ = c.virStreamFree(s);
            d.stream = null;
        }
        if (d.domain) |vm| {
            defer {
                _ = c.virDomainFree(vm);
                d.domain = null;
            }
            const active = c.virDomainIsActive(vm);
            if (active < 0) {
                if (c.virGetLastError()) |e| if (e.*.code == c.VIR_ERR_NO_DOMAIN) return;
                return lastError();
            }
            if (active == 1) try checked(c.virDomainDestroy(vm));
        }
    }
    pub fn recv(d: *Domain, buffer: []u8) !usize {
        return receive(d.stream, buffer);
    }
    pub fn recvAgent(d: *Domain, buffer: []u8) !usize {
        return receive(d.agent_stream, buffer);
    }
    fn receive(stream: c.virStreamPtr, buffer: []u8) !usize {
        const n = c.virStreamRecv(stream, buffer.ptr, buffer.len);
        if (n == -2) return 0;
        if (n < 0) return lastError();
        return @intCast(n);
    }
    pub fn send(d: *Domain, bytes: []const u8) !void {
        return transmit(d.stream, bytes);
    }
    pub fn sendAgent(d: *Domain, bytes: []const u8) !void {
        return transmit(d.agent_stream, bytes);
    }
    pub fn ejectInstaller(d: *Domain) !void {
        const xml = "<disk type='file' device='cdrom'><driver name='qemu' type='raw'/><target dev='sdb' bus='sata'/><readonly/></disk>";
        try checked(c.virDomainUpdateDeviceFlags(d.domain, xml, c.VIR_DOMAIN_AFFECT_LIVE));
    }
    fn transmit(stream: c.virStreamPtr, bytes: []const u8) !void {
        var offset: usize = 0;
        var blocked: usize = 0;
        while (offset < bytes.len) {
            const n = c.virStreamSend(stream, bytes[offset..].ptr, bytes.len - offset);
            if (n == -2) {
                blocked += 1;
                if (blocked > 500) return error.ConsoleWriteTimeout;
                _ = c.usleep(10000);
                continue;
            }
            if (n <= 0) return lastError();
            offset += @intCast(n);
        }
    }
    pub fn state(d: Domain) !struct { state: c_int, reason: c_int } {
        var s: c_int = 0;
        var reason: c_int = 0;
        if (c.virDomainGetState(d.domain, &s, &reason, 0) < 0) {
            if (c.virGetLastError()) |e| if (e.*.code == c.VIR_ERR_NO_DOMAIN) return .{ .state = c.VIR_DOMAIN_SHUTOFF, .reason = 0 };
            return lastError();
        }
        return .{ .state = s, .reason = reason };
    }
    pub fn screenshot(d: *Domain, io: std.Io, path: []const u8) !void {
        const stream = c.virStreamNew(d.connection, 0) orelse return lastError();
        defer _ = c.virStreamFree(stream);
        const mime = c.virDomainScreenshot(d.domain, stream, 0, 0) orelse return lastError();
        defer c.free(mime);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [65536]u8 = undefined;
        while (true) {
            const count = try receive(stream, &buf);
            if (count == 0) break;
            try file.writeStreamingAll(io, buf[0..count]);
        }
        try checked(c.virStreamFinish(stream));
    }
};
