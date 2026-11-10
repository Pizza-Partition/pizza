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
        // Retain the instance and callback context until the task returns,
        // including when an assertion fails.
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
        f.worker.startExecution(std.testing.io, session, &task, f, Fixture.run) catch |err| {
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

test "unavailable concurrency rolls back execution and allows retry" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var fixture: Fixture = .{};
    defer fixture.finish();
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expect(fixture.worker.writeLock());
    try std.testing.expectError(error.ConcurrencyUnavailable, fixture.worker.startExecution(threaded.io(), id, "owned task", &fixture, Fixture.run));
    try std.testing.expect(!fixture.received.load(.acquire));
    try std.testing.expect(!fixture.worker.executionActive(id));
    try std.testing.expect((try fixture.worker.currentId(std.testing.allocator)) == null);
    // Failure leaves the write lease with the caller, just as allocation failure does.
    try std.testing.expect(fixture.worker.busy());
    fixture.worker.writeUnlock();

    try std.testing.expect(fixture.worker.writeLock());
    fixture.worker.startExecution(std.testing.io, id, "owned task", &fixture, Fixture.run) catch |err| {
        fixture.worker.writeUnlock();
        return err;
    };
    fixture.finish();
    try std.testing.expect(fixture.received.load(.acquire));
    try std.testing.expect(!fixture.worker.busy());
}

test "worker task group can be reused after completion and repeated waits" {
    var fixture: Fixture = .{};
    defer fixture.finish();
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    for (0..3) |_| {
        fixture.gate.store(true, .release);
        fixture.received.store(false, .release);
        try std.testing.expect(fixture.worker.writeLock());
        fixture.worker.startExecution(std.testing.io, id, "owned task", &fixture, Fixture.run) catch |err| {
            fixture.worker.writeUnlock();
            return err;
        };
        try std.testing.expect(!fixture.worker.executionCancelled(id));
        try std.testing.expect(fixture.worker.cancelExecution(id));
        fixture.finish();
        fixture.worker.wait(std.testing.io);
        try std.testing.expect(fixture.received.load(.acquire));
        try std.testing.expect(!fixture.worker.busy());
        try std.testing.expect(!fixture.worker.executionActive(id));
        try std.testing.expect(!fixture.worker.executionCancelled(id));
    }
}
