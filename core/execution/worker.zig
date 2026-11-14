//! Concurrent task ownership and cancellation, independent of IPC and persistence.
const Worker = @This();
const std = @import("std");
const ALLOCATOR = std.heap.page_allocator;
writes: std.atomic.Value(bool) = .init(false),
mutex: std.atomic.Mutex = .unlocked,
active_id: [64]u8 = undefined,
active_present: bool = false,
cancel_requested: bool = false,
tasks: std.Io.Group = .init,

fn lock(self: *Worker) void {
    while (!self.mutex.tryLock()) std.Thread.yield() catch {};
}

pub fn writeLock(self: *Worker) bool {
    return self.writes.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
}

pub fn writeUnlock(self: *Worker) void {
    self.writes.store(false, .release);
}

pub fn busy(self: *const Worker) bool {
    return self.writes.load(.acquire);
}

/// Stop submitting work before waiting; retain the context until this returns.
/// Use the same Io backend that started the tasks. Shutdown must not cancel a
/// disk step: execution cancellation is handled separately between steps.
pub fn wait(self: *Worker, io: std.Io) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    self.tasks.await(io) catch unreachable;
}

fn matches(self: *const Worker, id: []const u8) bool {
    return isSessionId(id) and self.active_present and std.mem.eql(u8, &self.active_id, id);
}

pub fn executionActive(self: *Worker, id: []const u8) bool {
    self.lock();
    defer self.mutex.unlock();
    return self.matches(id);
}

pub fn cancelExecution(self: *Worker, id: []const u8) bool {
    self.lock();
    defer self.mutex.unlock();
    const active = self.matches(id);
    if (active) self.cancel_requested = true;
    return active;
}
pub fn executionCancelled(self: *Worker, id: []const u8) bool {
    self.lock();
    defer self.mutex.unlock();
    return self.matches(id) and self.cancel_requested;
}
pub fn currentId(self: *Worker, a: std.mem.Allocator) !?[]const u8 {
    self.lock();
    defer self.mutex.unlock();
    return if (self.active_present) try a.dupe(u8, &self.active_id) else null;
}

pub const Callback = *const fn (?*anyopaque, []const u8) void;

const Work = struct {
    worker: *Worker,
    task: []u8,
    context: ?*anyopaque,
    run: Callback,
};

fn executeTask(work: Work) void {
    const self = work.worker;
    work.run(work.context, work.task);
    ALLOCATOR.free(work.task);
    self.lock();
    self.active_present = false;
    self.cancel_requested = false;
    self.mutex.unlock();
    self.writeUnlock();
}

pub fn startExecution(self: *Worker, io: std.Io, id: []const u8, task: []const u8, context: ?*anyopaque, run: Callback) !void {
    if (!isSessionId(id) or task.len > 8 * 1024 * 1024 or !self.busy()) return error.InvalidExecution;
    const work: Work = .{ .worker = self, .task = try ALLOCATOR.dupe(u8, task), .context = context, .run = run };
    errdefer ALLOCATOR.free(work.task);
    self.lock();
    defer self.mutex.unlock();
    if (self.active_present) return error.ExecutionInProgress;
    @memcpy(&self.active_id, id);
    self.active_present = true;
    self.cancel_requested = false;
    errdefer self.active_present = false;
    try self.tasks.concurrent(io, executeTask, .{work});
}

/// Session keys are bounded lowercase hex; they can also be used as file names.
pub fn isSessionId(id: []const u8) bool {
    return id.len == 64 and std.mem.indexOfNone(u8, id, "0123456789abcdef") == null;
}
