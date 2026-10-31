//! Authorize the current executable and exchange requests without replaying writes.
const std = @import("std");
const c = @import("libc");
const transport = @import("transport.zig");
const ownership = @import("store.zig");
const validId = @import("../../../execution/worker.zig").validId;
fn exchange(a: std.mem.Allocator, request: []const u8, submitted: *bool) !?[]const u8 {
    submitted.* = false;
    var key_buffer: [256]u8 = undefined;
    const key = try std.mem.printSentinel(&key_buffer, "/run/user/{d}/pizza-session", .{c.getuid()}, 0);
    const file = c.open(key, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (file < 0) return null;
    var nonce: [64]u8 = undefined;
    {
        defer _ = c.close(file);
        var stat: c.struct_stat = undefined;
        if (c.fstat(file, &stat) != 0 or !ownership.regular(stat, c.getuid()) or stat.st_size != 64 or !transport.readExact(file, &nonce) or !validId(&nonce)) return null;
    }
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    transport.deadline(fd);
    var sock_buffer: [108]u8 = undefined;
    var addr = try transport.address(try std.fmt.bufPrint(&sock_buffer, "/run/pizza/{d}/control.sock", .{c.getuid()}));
    if (c.connect(fd, .{ .__sockaddr_un__ = &addr }, @sizeOf(@TypeOf(addr))) != 0 or !transport.peerIs(fd, 0)) return null;
    if (!transport.sendAll(fd, &nonce) or !transport.sendAll(fd, "\n")) return null;
    // Sending any request bytes transfers replay responsibility to the session.
    submitted.* = true;
    if (!transport.sendAll(fd, request)) return null;
    _ = c.shutdown(fd, c.SHUT_WR);
    return transport.readBounded(a, fd, 8 * 1024 * 1024) catch null;
}
pub fn call(a: std.mem.Allocator, request: []const u8) !?[]const u8 {
    var submitted = false;
    return exchange(a, request, &submitted);
}
fn currentExecutable(buffer: []u8) ?[:0]const u8 {
    const n = c.readlink("/proc/self/exe", buffer.ptr, buffer.len - 1);
    if (n <= 0 or n >= buffer.len - 1 or buffer[0] != '/') return null;
    const length: usize = @intCast(n);
    buffer[length] = 0;
    const path = buffer[0..length :0];
    var running: c.struct_stat = undefined;
    var target: c.struct_stat = undefined;
    if (c.stat("/proc/self/exe", &running) != 0 or c.stat(path, &target) != 0 or target.st_mode & c.S_IFMT != c.S_IFREG or target.st_mode & 0o111 == 0 or running.st_dev != target.st_dev or running.st_ino != target.st_ino) return null;
    return path;
}
fn authorizationTool() ?[:0]const u8 {
    for ([_][:0]const u8{ "/usr/bin/run0", "/usr/bin/pkexec", "/usr/bin/kdesudo" }) |path| if (c.access(path, c.X_OK) == 0) return path;
    return null;
}
pub const Readiness = enum { ready, executable_changed, authorization_unavailable };
pub fn readiness() Readiness {
    var buffer: [4096]u8 = undefined;
    if (currentExecutable(&buffer) == null) return .executable_changed;
    return if (authorizationTool() == null) .authorization_unavailable else .ready;
}
fn reapProcess(pid: c.pid_t) void {
    while (c.waitpid(pid, null, 0) < 0 and c.__errno_location().* == c.EINTR) {}
}
const RESPONSE_LOST = "{\"error\":\"execution_response_lost\",\"message\":\"The request may have been accepted. Reconnect to the execution session; do not resubmit the plan.\"}";
pub fn elevate(a: std.mem.Allocator, request: []const u8) !?[]const u8 {
    var submitted = false;
    if (try exchange(a, request, &submitted)) |result| return result;
    if (submitted) return RESPONSE_LOST;
    var random: [32]u8 = undefined;
    if (c.getrandom(&random, random.len, 0) != random.len) return null;
    const nonce = std.fmt.bytesToHex(random, .lower);
    var self_buffer: [4096]u8 = undefined;
    const self = currentExecutable(&self_buffer) orelse return "{\"error\":\"executable_changed\",\"message\":\"This running build was moved or replaced. Restart Pizza before authorizing access.\"}";
    const authorizer = authorizationTool() orelse return "{\"error\":\"authorization_unavailable\",\"message\":\"run0, pkexec or kdesudo is required for the administrator prompt.\"}";
    var input: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &input) != 0) return null;
    defer _ = c.close(input[1]);
    var output: [2]c_int = undefined;
    if (c.pipe2(&output, c.O_CLOEXEC) != 0) {
        _ = c.close(input[0]);
        return null;
    }
    defer _ = c.close(output[0]);
    const pid = c.fork();
    if (pid == 0) {
        _ = c.dup2(input[0], 0);
        _ = c.dup2(output[1], 1);
        for ([_]c_int{ input[0], input[1], output[0], output[1] }) |fd| _ = c.close(fd);
        if (c.chdir("/") != 0) c._exit(127);
        const run0 = [_:null]?[*:0]const u8{ "run0", "--pipe", "--chdir=/", self.ptr, "privileged-exec" };
        const pkexec = [_:null]?[*:0]const u8{ "pkexec", "--disable-internal-agent", self.ptr, "privileged-exec" };
        const kdesudo = [_:null]?[*:0]const u8{ "kdesudo", "--comment", "Pizza needs administrator access", "-d", "--", self.ptr, "privileged-exec" };
        const argv = if (std.mem.eql(u8, authorizer, "/usr/bin/run0")) @as([*c]const [*c]u8, @ptrCast(&run0)) else if (std.mem.eql(u8, authorizer, "/usr/bin/pkexec")) @as([*c]const [*c]u8, @ptrCast(&pkexec)) else @as([*c]const [*c]u8, @ptrCast(&kdesudo));
        _ = c.execv(authorizer, argv);
        c._exit(127);
    }
    _ = c.close(input[0]);
    _ = c.close(output[1]);
    if (pid < 0) return null;
    if (std.Thread.spawn(.{}, reapProcess, .{pid})) |thread| thread.detach() else |_| {}
    if (!transport.sendAll(input[1], &nonce) or !transport.sendAll(input[1], "\n")) return null;
    _ = c.shutdown(input[1], c.SHUT_WR);
    var ready: [6]u8 = undefined;
    if (!transport.readExact(output[0], &ready) or !std.mem.eql(u8, &ready, "READY\n")) return "{\"error\":\"authorization_failed\",\"message\":\"Administrator authorization was cancelled or the service could not start. Check that a polkit authentication agent is running. The draft is unchanged.\"}";
    var key_buffer: [256]u8 = undefined;
    const key = try std.mem.printSentinel(&key_buffer, "/run/user/{d}/pizza-session", .{c.getuid()}, 0);
    const file = c.open(key, c.O_CREAT | c.O_TRUNC | c.O_WRONLY | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c.mode_t, 0o600));
    if (file < 0) return null;
    {
        defer _ = c.close(file);
        var stat: c.struct_stat = undefined;
        if (c.fstat(file, &stat) != 0 or !ownership.regular(stat, c.getuid()) or c.fchmod(file, 0o600) != 0 or !transport.writeAll(file, &nonce)) return null;
    }
    const result = try exchange(a, request, &submitted);
    return if (result == null and submitted) RESPONSE_LOST else result;
}

test "development executable does not require a root-owned installation" {
    try std.testing.expect(readiness() != .executable_changed);
}
