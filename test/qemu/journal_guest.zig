//! Disposable two-boot fixture. It mounts only the QEMU runner's private disk.
const std = @import("std");
const linux = std.os.linux;
const journal = @import("journal");
const power = @import("power");

pub fn main(init: std.process.Init) !void {
    if (linux.getpid() != 1) return error.NotPid1;
    run(init.arena.allocator(), init.io) catch |err| std.log.err("PIZZA_JOURNAL_TEST_FAILED: {t}", .{err});
    power.poweroff() catch {};
    while (true) _ = linux.pause();
}

fn run(a: std.mem.Allocator, io: std.Io) !void {
    try @import("mounts").setup(io);
    try std.Io.Dir.cwd().createDirPath(io, "/journal");
    // The static fixture requires virtio and ext4 built into its supplied kernel.
    if (linux.errno(linux.mount("/dev/vda", "/journal", "ext4", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, 0)) != .SUCCESS)
        return error.TestJournalMountFailed;
    var directory = try std.Io.Dir.cwd().openDir(io, "/journal", .{});
    const command = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/cmdline", a, .limited(16 * 1024));
    const anchor = try journal.captureBoundary(a, io, .{
        .state = .start,
        .boot_id = "",
        .utc_unix_ns = "",
        .plan_id = "qemu_journal",
        .home = .{ .kind = .other_device, .path = "/journal" },
    });
    if (std.mem.indexOf(u8, command, "pizza.journal_test=write") != null) {
        var writer = try journal.Writer.create(a, io, directory, anchor.boundary, anchor.monotonic_ns, .{});
        _ = try writer.intent(io, 1, try journal.monotonicNow(io), "simulated step one");
        _ = try writer.commit(io, 1, try journal.monotonicNow(io), "done");
        _ = try writer.intent(io, 2, try journal.monotonicNow(io), "simulated step two");
        _ = try writer.fail(io, 2, try journal.monotonicNow(io), "expected failure");
        _ = try writer.intent(io, 3, try journal.monotonicNow(io), "interrupted before outcome");
        writer.close(io);
        std.log.info("PIZZA_JOURNAL_WRITE_READY", .{});
    } else if (std.mem.indexOf(u8, command, "pizza.journal_test=read") != null) {
        const parsed = try journal.readFile(a, io, "/journal/journal.bin");
        if (parsed.tail != .clean or parsed.state.seq != 6 or parsed.state.steps.get(1).?.state != .succeeded or parsed.state.steps.get(2).?.state != .failed or parsed.state.steps.get(3).?.state != .in_flight)
            return error.TestJournalStateMismatch;
        if (std.mem.eql(u8, parsed.state.boundary.?.boot_id, anchor.boundary.boot_id)) return error.TestMustUseDifferentBoot;
        var writer = try journal.Writer.open(a, io, directory, anchor.boundary, anchor.monotonic_ns, .{});
        const seq = try writer.note(io, 3, try journal.monotonicNow(io), "still in flight after reboot");
        if (seq != 8) return error.TestSequenceNotContinued;
        writer.close(io);
        std.log.info("PIZZA_JOURNAL_RECOVERY_READY: succeeded failed in_flight; distinct boot IDs", .{});
    } else return error.TestModeMissing;
    directory.close(io);
    if (linux.errno(linux.umount2("/journal", 0)) != .SUCCESS) return error.TestUnmountFailed;
    std.log.info("PIZZA_JOURNAL_UNMOUNTED", .{});
}
