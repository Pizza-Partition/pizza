//! Authorize the current executable and exchange requests without replaying writes.
const std = @import("std");
const libc = @import("libc");
const transport = @import("transport.zig");
const ownership = @import("store.zig");
const isSessionId = @import("../../../execution/worker.zig").isSessionId;
fn exchange(a: std.mem.Allocator, request: []const u8, submitted: *bool) !?[]const u8 {
    submitted.* = false;
    var key_buffer: [256]u8 = undefined;
    const key = try std.mem.printSentinel(&key_buffer, "/run/user/{d}/pizza-session", .{libc.getuid()}, 0);
    var socket_buffer: [108]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_buffer, "/run/pizza/{d}/control.sock", .{libc.getuid()});
    return exchangeAt(a, request, submitted, key, socket_path);
}
fn exchangeAt(a: std.mem.Allocator, request: []const u8, submitted: *bool, key: [:0]const u8, socket_path: []const u8) !?[]const u8 {
    submitted.* = false;
    const file = libc.open(key, libc.O_RDONLY | libc.O_CLOEXEC | libc.O_NOFOLLOW);
    if (file < 0) {
        if (libc.__errno_location().* == libc.ENOENT) return null;
        return systemFailure("open session record");
    }
    var nonce: [64]u8 = undefined;
    {
        defer _ = libc.close(file);
        var stat: libc.struct_stat = undefined;
        if (libc.fstat(file, &stat) != 0) return systemFailure("stat session record");
        if (!ownership.regular(stat, libc.getuid())) return error.UnsafeSessionFile;
        if (stat.st_size != 64 or !transport.readExact(file, &nonce) or !isSessionId(&nonce)) return error.InvalidSessionReference;
    }
    const fd = libc.socket(libc.AF_UNIX, libc.SOCK_STREAM | libc.SOCK_CLOEXEC, 0);
    if (fd < 0) return systemFailure("create session socket");
    defer _ = libc.close(fd);
    try transport.deadline(fd);
    var addr = try transport.address(socket_path);
    if (libc.connect(fd, .{ .__sockaddr_un__ = &addr }, @sizeOf(@TypeOf(addr))) != 0) {
        const err = libc.__errno_location().*;
        if (err == libc.ENOENT or err == libc.ECONNREFUSED) return null;
        return systemFailure("connect session socket");
    }
    if (!transport.peerIs(fd, 0)) return error.UntrustedSessionPeer;
    if (!transport.sendAll(fd, &nonce) or !transport.sendAll(fd, "\n")) return error.IpcAuthenticationFailed;
    // Sending any request bytes transfers replay responsibility to the session.
    submitted.* = true;
    if (!transport.sendAll(fd, request)) return RESPONSE_LOST;
    _ = libc.shutdown(fd, libc.SHUT_WR);
    const response = transport.readBounded(a, fd, 8 * 1024 * 1024) catch |err| {
        std.log.warn("Session response lost after request submission: {t}", .{err});
        return RESPONSE_LOST;
    };
    return if (response.len == 0) RESPONSE_LOST else response;
}
pub fn call(a: std.mem.Allocator, request: []const u8) !?[]const u8 {
    var submitted = false;
    return exchange(a, request, &submitted);
}
fn currentExecutable(buffer: []u8) ?[:0]const u8 {
    const n = libc.readlink("/proc/self/exe", buffer.ptr, buffer.len - 1);
    if (n <= 0 or n >= buffer.len - 1 or buffer[0] != '/') return null;
    const length: usize = @intCast(n);
    buffer[length] = 0;
    const path = buffer[0..length :0];
    var running: libc.struct_stat = undefined;
    var target: libc.struct_stat = undefined;
    if (libc.stat("/proc/self/exe", &running) != 0 or libc.stat(path, &target) != 0 or target.st_mode & libc.S_IFMT != libc.S_IFREG or target.st_mode & 0o111 == 0 or running.st_dev != target.st_dev or running.st_ino != target.st_ino) return null;
    return path;
}
fn authorizationTool() ?[:0]const u8 {
    for ([_][:0]const u8{ "/usr/bin/run0", "/usr/bin/pkexec", "/usr/bin/kdesudo" }) |path| if (libc.access(path, libc.X_OK) == 0) return path;
    return null;
}
pub const Readiness = enum { ready, executable_changed, authorization_unavailable };
pub fn readiness() Readiness {
    var buffer: [4096]u8 = undefined;
    if (currentExecutable(&buffer) == null) return .executable_changed;
    return if (authorizationTool() == null) .authorization_unavailable else .ready;
}
fn reapProcess(pid: libc.pid_t) void {
    while (libc.waitpid(pid, null, 0) < 0 and libc.__errno_location().* == libc.EINTR) {}
}
const RESPONSE_LOST = "{\"error\":\"execution_response_lost\",\"message\":\"The request may have been accepted. Reconnect to the execution session; do not resubmit the plan.\"}";
pub fn elevate(a: std.mem.Allocator, request: []const u8) !?[]const u8 {
    var submitted = false;
    if (try exchange(a, request, &submitted)) |result| return result;
    if (submitted) return RESPONSE_LOST;
    var random: [32]u8 = undefined;
    if (libc.getrandom(&random, random.len, 0) != random.len) return error.SecureRandomUnavailable;
    const nonce = std.fmt.bytesToHex(random, .lower);
    var self_buffer: [4096]u8 = undefined;
    const self = currentExecutable(&self_buffer) orelse return "{\"error\":\"executable_changed\",\"message\":\"This running build was moved or replaced. Restart Pizza before authorizing access.\"}";
    const authorizer = authorizationTool() orelse return "{\"error\":\"authorization_unavailable\",\"message\":\"run0, pkexec or kdesudo is required for the administrator prompt.\"}";
    var input: [2]c_int = undefined;
    if (libc.socketpair(libc.AF_UNIX, libc.SOCK_STREAM | libc.SOCK_CLOEXEC, 0, &input) != 0) return systemFailure("create authorization socket");
    defer _ = libc.close(input[1]);
    var output: [2]c_int = undefined;
    if (libc.pipe2(&output, libc.O_CLOEXEC) != 0) {
        const err = systemFailure("create authorization pipe");
        _ = libc.close(input[0]);
        return err;
    }
    defer _ = libc.close(output[0]);
    const pid = libc.fork();
    if (pid == 0) {
        _ = libc.dup2(input[0], 0);
        _ = libc.dup2(output[1], 1);
        for ([_]c_int{ input[0], input[1], output[0], output[1] }) |fd| _ = libc.close(fd);
        if (libc.chdir("/") != 0) libc._exit(127);
        const run0 = [_:null]?[*:0]const u8{ "run0", "--pipe", "--chdir=/", self.ptr, "privileged-exec" };
        const pkexec = [_:null]?[*:0]const u8{ "pkexec", "--disable-internal-agent", self.ptr, "privileged-exec" };
        const kdesudo = [_:null]?[*:0]const u8{ "kdesudo", "--comment", "Pizza needs administrator access", "-d", "--", self.ptr, "privileged-exec" };
        const argv = if (std.mem.eql(u8, authorizer, "/usr/bin/run0")) @as([*c]const [*c]u8, @ptrCast(&run0)) else if (std.mem.eql(u8, authorizer, "/usr/bin/pkexec")) @as([*c]const [*c]u8, @ptrCast(&pkexec)) else @as([*c]const [*c]u8, @ptrCast(&kdesudo));
        _ = libc.execv(authorizer, argv);
        libc._exit(127);
    }
    _ = libc.close(input[0]);
    _ = libc.close(output[1]);
    if (pid < 0) return systemFailure("start authorizer");
    if (std.Thread.spawn(.{}, reapProcess, .{pid})) |thread| thread.detach() else |_| {}
    if (!transport.sendAll(input[1], &nonce) or !transport.sendAll(input[1], "\n")) return error.IpcAuthenticationFailed;
    _ = libc.shutdown(input[1], libc.SHUT_WR);
    var ready: [6]u8 = undefined;
    if (!transport.readExact(output[0], &ready) or !std.mem.eql(u8, &ready, "READY\n")) return "{\"error\":\"authorization_failed\",\"message\":\"Administrator authorization was cancelled or the service could not start. Check that a polkit authentication agent is running. The draft is unchanged.\"}";
    var key_buffer: [256]u8 = undefined;
    const key = try std.mem.printSentinel(&key_buffer, "/run/user/{d}/pizza-session", .{libc.getuid()}, 0);
    const file = libc.open(key, libc.O_CREAT | libc.O_TRUNC | libc.O_WRONLY | libc.O_CLOEXEC | libc.O_NOFOLLOW, @as(libc.mode_t, 0o600));
    if (file < 0) return systemFailure("publish session reference");
    {
        defer _ = libc.close(file);
        var stat: libc.struct_stat = undefined;
        if (libc.fstat(file, &stat) != 0) return systemFailure("stat new session reference");
        if (!ownership.regular(stat, libc.getuid())) return error.UnsafeSessionFile;
        if (libc.fchmod(file, 0o600) != 0 or !transport.writeAll(file, &nonce)) return systemFailure("write session reference");
    }
    const result = try exchange(a, request, &submitted);
    return if (result == null and submitted) RESPONSE_LOST else result;
}

test "development executable does not require a root-owned installation" {
    try std.testing.expect(readiness() != .executable_changed);
}

fn classifyFailure(err: c_int) anyerror {
    return switch (err) {
        libc.EACCES, libc.EPERM => error.AccessDenied,
        libc.EMFILE, libc.ENFILE => error.IpcDescriptorLimit,
        libc.ENOMEM, libc.ENOBUFS => error.OutOfMemory,
        libc.ELOOP => error.UnsafeSessionFile,
        libc.ETIMEDOUT, libc.EAGAIN => error.IpcTimeout,
        else => error.IpcCommunicationFailed,
    };
}
fn systemFailure(operation: []const u8) anyerror {
    const err = libc.__errno_location().*;
    std.log.warn("IPC {s} failed (errno {d})", .{ operation, err });
    return classifyFailure(err);
}

test "IPC resource and permission failures are distinct from an absent helper" {
    try std.testing.expectEqual(error.AccessDenied, classifyFailure(libc.EACCES));
    try std.testing.expectEqual(error.IpcDescriptorLimit, classifyFailure(libc.EMFILE));
    try std.testing.expectEqual(error.IpcTimeout, classifyFailure(libc.EAGAIN));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const key = try std.fmt.allocPrintSentinel(a, "{s}/reference", .{root}, 0);
    defer a.free(key);
    const socket = try std.fmt.allocPrint(a, "{s}/absent.sock", .{root});
    defer a.free(socket);
    var submitted = false;
    try std.testing.expectEqual(@as(?[]const u8, null), try exchangeAt(a, "{}", &submitted, key, socket));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "reference", .data = "truncated" });
    try std.testing.expectEqual(@as(c_int, 0), libc.chmod(key, 0o600));
    try std.testing.expectError(error.InvalidSessionReference, exchangeAt(a, "{}", &submitted, key, socket));
    try std.testing.expect(!submitted);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "reference", .data = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" });
    try std.testing.expectEqual(@as(?[]const u8, null), try exchangeAt(a, "{}", &submitted, key, socket));
    try std.testing.expect(!submitted);
}
