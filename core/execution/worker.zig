//! Detached task ownership and cancellation, independent of IPC and persistence.
const Worker = @This();
const std = @import("std");
const ALLOCATOR = std.heap.page_allocator;
writes: std.atomic.Value(bool) = .init(false),
control: std.atomic.Mutex = .unlocked,
active_id: [64]u8 = undefined,
active_present: bool = false,
cancel_requested: bool = false,

fn lock(self: *Worker) void {
    while (!self.control.tryLock()) std.Thread.yield() catch {};
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
/// The owner must retain its context until the detached callback has returned.
pub fn wait(self: *const Worker, io: std.Io) void {
    while (self.busy()) std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {
        std.Thread.yield() catch {};
    };
}
fn matches(self: *const Worker, id: []const u8) bool {
    return validId(id) and self.active_present and std.mem.eql(u8, &self.active_id, id);
}
pub fn executionActive(self: *Worker, id: []const u8) bool {
    self.lock();
    defer self.control.unlock();
    return self.matches(id);
}
pub fn cancelExecution(self: *Worker, id: []const u8) bool {
    self.lock();
    defer self.control.unlock();
    const active = self.matches(id);
    if (active) self.cancel_requested = true;
    return active;
}
pub fn executionCancelled(self: *Worker, id: []const u8) bool {
    self.lock();
    defer self.control.unlock();
    return self.matches(id) and self.cancel_requested;
}
pub fn currentId(self: *Worker, a: std.mem.Allocator) !?[]const u8 {
    self.lock();
    defer self.control.unlock();
    return if (self.active_present) try a.dupe(u8, &self.active_id) else null;
}
pub const Callback = *const fn (?*anyopaque, []const u8) void;
const Work = struct { worker: *Worker, task: []u8, context: ?*anyopaque, run: Callback };
fn executeTask(work: *Work) void {
    const self = work.worker;
    defer {
        ALLOCATOR.free(work.task);
        ALLOCATOR.destroy(work);
        self.lock();
        self.active_present = false;
        self.cancel_requested = false;
        self.control.unlock();
        self.writeUnlock();
    }
    work.run(work.context, work.task);
}
pub fn startExecution(self: *Worker, id: []const u8, task: []const u8, context: ?*anyopaque, run: Callback) !void {
    if (!validId(id) or task.len > 8 * 1024 * 1024 or !self.busy()) return error.InvalidExecution;
    const work = try ALLOCATOR.create(Work);
    errdefer ALLOCATOR.destroy(work);
    work.* = .{ .worker = self, .task = try ALLOCATOR.dupe(u8, task), .context = context, .run = run };
    errdefer ALLOCATOR.free(work.task);
    self.lock();
    defer self.control.unlock();
    if (self.active_present) return error.ExecutionInProgress;
    @memcpy(&self.active_id, id);
    self.active_present = true;
    self.cancel_requested = false;
    errdefer self.active_present = false;
    const thread = try std.Thread.spawn(.{}, executeTask, .{work});
    thread.detach();
}

/// Session keys are bounded lowercase hex; they can also be used as file names.
pub fn validId(id: []const u8) bool {
    if (id.len != 64) return false;
    for (id) |byte| if (!(byte >= '0' and byte <= '9' or byte >= 'a' and byte <= 'f')) return false;
    return true;
}
