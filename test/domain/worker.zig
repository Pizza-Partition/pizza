const std = @import("std");
const Worker = @import("../../core/execution/worker.zig");
const Fixture = struct {
    worker: Worker = .{},
    gate: std.atomic.Value(bool) = .init(true),
    received: std.atomic.Value(bool) = .init(false),
    fn run(context: ?*anyopaque, task: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.received.store(std.mem.eql(u8, task, "owned task"), .release);
        while (self.gate.load(.acquire)) std.Thread.yield() catch {};
    }
    fn finish(self: *@This()) void {
        self.gate.store(false, .release);
        // Keep the instance and callback context alive until the detached task
        // has cleared its state and released its write lease, also on failure.
        self.worker.wait(std.testing.io);
    }
};
test "workers own copied tasks and isolate cancellation and write leases" {
    var first: Fixture = .{};
    var second: Fixture = .{};
    defer first.finish();
    defer second.finish();
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const other = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    var task = "owned task".*;
    for ([_]*Fixture{ &first, &second }, [_][]const u8{ id, other }) |f, session| {
        try std.testing.expect(f.worker.writeLock());
        f.worker.startExecution(session, &task, f, Fixture.run) catch |err| {
            f.worker.writeUnlock();
            return err;
        };
    }
    @memset(&task, 'x');
    try std.testing.expect(!first.worker.writeLock());
    try std.testing.expect(!second.worker.writeLock());
    try std.testing.expect(first.worker.executionActive(id));
    try std.testing.expect(second.worker.executionActive(other));
    try std.testing.expect(!first.worker.cancelExecution(other));
    try std.testing.expect(first.worker.cancelExecution(id));
    try std.testing.expect(first.worker.executionCancelled(id));
    try std.testing.expect(!second.worker.executionCancelled(other));
    first.finish();
    second.finish();
    try std.testing.expect(first.received.load(.acquire));
    try std.testing.expect(second.received.load(.acquire));
    try std.testing.expect(!first.worker.executionActive(id));
    try std.testing.expect(!second.worker.executionActive(other));
}
