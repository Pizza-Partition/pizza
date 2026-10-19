//! File-descriptor kexec only. Shutdown uses ordinary systemd, without --force.
const std = @import("std");
const linux = std.os.linux;
const session = @import("session");
const utils = @import("utils");
const state = @import("state.zig");
const image = @import("image.zig");

pub const Options = struct {
    workspace: []const u8 = "/run/pizza/transition",
    kernel: ?[]const u8 = null,
    initrd: ?[]const u8 = null,
    plan: ?[]const u8 = null,
    journal_device: ?[]const u8 = null,
    journal_home: ?[]const u8 = null,
    no_ui: bool = false,
    test_poweroff: bool = false,
};
fn workspace(io: std.Io, path: []const u8, create: bool) !std.Io.Dir {
    if (linux.geteuid() != 0) return error.TransitionRequiresRoot;
    if (!std.fs.path.isAbsolute(path)) return error.AbsolutePathRequired;
    try utils.filesystem.checkPath(path[1..]);
    if (create) {
        var parent = std.fs.path.dirname(path) orelse return error.AbsolutePathRequired;
        while (true) {
            var ancestor = session.storage.openTrusted(io, parent) catch |err| {
                if (err != error.FileNotFound) return err;
                parent = std.fs.path.dirname(parent) orelse return err;
                continue;
            };
            defer ancestor.close(io);
            if (try utils.filesystem.filesystemType(ancestor) != utils.filesystem.tmpfs_magic) return error.TransitionWorkspaceMustBePrivateTmpfs;
            break;
        }
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, path, .fromMode(0o700));
    }
    var directory = try session.storage.openTrusted(io, path);
    errdefer directory.close(io);
    if (try utils.filesystem.filesystemType(directory) != utils.filesystem.tmpfs_magic or (try directory.stat(io)).permissions.toMode() & 0o077 != 0) return error.TransitionWorkspaceMustBePrivateTmpfs;
    return directory;
}
pub fn staged(a: std.mem.Allocator, io: std.Io, options: Options) !state.Stage {
    const kernel = options.kernel orelse return error.MissingKernel;
    const initrd = options.initrd orelse return error.MissingInitrd;
    const plan_file = options.plan orelse return error.MissingExecutionPlan;
    const device = options.journal_device orelse return error.MissingJournalDevice;
    const home = options.journal_home orelse return error.MissingJournalHome;
    if (linux.geteuid() != 0) return error.TransitionRequiresRoot;
    _ = try image.validate(a, io, kernel, initrd);
    const plan_bytes = try std.Io.Dir.cwd().readFileAlloc(io, plan_file, a, .limited(1024 * 1024));
    const plan = try std.json.parseFromSliceLeaky(@import("proto").Plan, a, plan_bytes, .{});
    try @import("proto").validatePlan(plan);
    const selected = try session.storage.select(a, io, device, home);
    var home_dir = try session.storage.openTrusted(io, home);
    defer home_dir.close(io);
    if (home_dir.access(io, "transition.json", .{})) return error.TransitionAlreadyExists else |err| if (err != error.FileNotFound) return err;
    if (home_dir.access(io, "plan.json", .{})) return error.TransitionPlanAlreadyExists else |err| if (err != error.FileNotFound) return err;
    try session.storage.syncParents(io, home);
    var random: [16]u8 = undefined;
    std.Io.random(io, &random);
    const request: session.Request = .{
        .session_id = try a.dupe(u8, &std.fmt.bytesToHex(random, .lower)),
        .source_boot_id = try session.bootId(a, io),
        .plan_id = plan.id,
        .plan_sha256 = try session.digest(a, plan_bytes),
        .home = selected,
        .no_ui = options.no_ui,
        .test_poweroff = options.test_poweroff,
    };
    try request.validate();
    var directory = try workspace(io, options.workspace, true);
    defer directory.close(io);
    const lock = try directory.createFile(io, "lock", .{ .truncate = false, .permissions = .fromMode(0o600), .lock = .exclusive, .lock_nonblocking = true });
    defer lock.close(io);
    if (directory.access(io, "stage.json", .{})) return error.StageAlreadyExists else |err| if (err != error.FileNotFound) return err;
    try image.stage(a, io, directory, kernel, initrd, request, plan_bytes);
    const value: state.Stage = .{
        .request = request,
        .kernel_sha256 = try utils.filesystem.hashFileSha256(a, io, try std.fs.path.join(a, &.{ options.workspace, "kernel" })),
        .initrd_sha256 = try utils.filesystem.hashFileSha256(a, io, try std.fs.path.join(a, &.{ options.workspace, "maint.img" })),
        .journal_home = home,
        .journal_device = device,
        .cmdline = try a.print("console=tty0 console=ttyS0 rdinit=/init panic=0 pizza.plan_id={s} pizza.kiosk={s}{s}", .{ plan.id, if (options.no_ui) "disable" else "enable", if (options.test_poweroff) " pizza.boot=transition_test" else "" }),
    };
    try session.writeExclusive(io, directory, "stage.json", try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 }));
    try session.writeExclusive(io, home_dir, "plan.json", plan_bytes);
    try session.writeMarker(a, io, home_dir, .{ .request = request, .status = .staged }, true);
    std.log.info("PIZZA_TRANSITION_STAGED: verified RAM image and independent durable journal home", .{});
    return value;
}
pub fn loaded(a: std.mem.Allocator, io: std.Io) !bool {
    const value = std.mem.trim(u8, try session.readProc(a, io, "/sys/kernel/kexec_loaded", 16), " \r\n");
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "0")) return false;
    return error.InvalidKexecLoadedState;
}
pub fn load(kernel: std.Io.File, initrd: std.Io.File, cmdline: [:0]const u8) !void {
    const err = linux.errno(linux.syscall5(.kexec_file_load, @intCast(kernel.handle), @intCast(initrd.handle), cmdline.len + 1, @intFromPtr(cmdline.ptr), 0));
    if (err == .SUCCESS) return;
    std.log.err("kexec_file_load refused: {t}; no shutdown requested", .{err});
    if (err == .PERM or err == .ACCES or err == .KEYREJECTED or err == .NOKEY)
        std.log.err("File kexec requires CAP_SYS_BOOT and a kernel accepted by the current lockdown/signature policy; use an accepted signed kernel or boot the maintenance image normally", .{});
    return switch (err) {
        .PERM, .ACCES => error.KexecPermissionOrLockdown,
        .KEYREJECTED, .NOKEY => error.KernelSignatureRejected,
        .NOSYS => error.KexecFileLoadUnavailable,
        .NOMEM => error.KexecInsufficientMemory,
        else => error.KexecLoadFailed,
    };
}
pub fn unload() !void {
    if (linux.errno(linux.syscall5(.kexec_file_load, 0, 0, 0, 0, 1)) != .SUCCESS) return error.KexecUnloadFailed;
}
pub fn transition(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, path: []const u8) !void {
    var directory = try workspace(io, path, false);
    defer directory.close(io);
    const lock = try directory.openFile(io, "lock", .{ .mode = .read_write, .follow_symlinks = false, .lock = .exclusive, .lock_nonblocking = true });
    defer lock.close(io);
    const value = try state.read(a, io, directory);
    if (!std.mem.eql(u8, value.request.source_boot_id, try session.bootId(a, io))) return error.StageBelongsToAnotherBoot;
    const selected = try session.storage.select(a, io, value.journal_device, value.journal_home);
    if (!std.mem.eql(u8, selected.uuid, value.request.home.uuid) or !std.mem.eql(u8, selected.path, value.request.home.path)) return error.JournalIdentityChanged;
    var home = try session.storage.openTrusted(io, value.journal_home);
    defer home.close(io);
    var marker = try session.readMarker(a, io, home);
    if (marker.status != .staged or !std.mem.eql(u8, try std.json.Stringify.valueAlloc(a, marker.request, .{}), try std.json.Stringify.valueAlloc(a, value.request, .{}))) return error.StaleOrMismatchedTransition;
    if (!std.mem.eql(u8, value.kernel_sha256, try utils.filesystem.hashFileSha256(a, io, try std.fs.path.join(a, &.{ path, "kernel" }))) or !std.mem.eql(u8, value.initrd_sha256, try utils.filesystem.hashFileSha256(a, io, try std.fs.path.join(a, &.{ path, "maint.img" })))) return error.StagedImageChanged;
    var pid1 = try std.Io.Dir.cwd().openDir(io, "/run/systemd/system", .{});
    defer pid1.close(io);
    _ = try utils.process.findExecutable(a, io, env, "systemctl");
    if (try loaded(a, io)) return error.AnotherKernelAlreadyLoaded;
    const kernel = try directory.openFile(io, "kernel", .{ .follow_symlinks = false });
    defer kernel.close(io);
    const initrd = try directory.openFile(io, "maint.img", .{ .follow_symlinks = false });
    defer initrd.close(io);
    try load(kernel, initrd, try a.dupeSentinel(u8, value.cmdline, 0));
    errdefer {
        const cleared = blk: {
            unload() catch |err| {
                std.log.err("Rollback: {t}; retaining loaded marker", .{err});
                break :blk false;
            };
            const remains = loaded(a, io) catch {
                std.log.err("Rollback could not confirm kernel unload; retaining loaded marker", .{});
                break :blk false;
            };
            break :blk !remains;
        };
        if (cleared) {
            marker.status = .staged;
            session.writeMarker(a, io, home, marker, false) catch |err| std.log.err("Marker rollback: {t}", .{err});
        } else std.log.err("Rollback incomplete; inspect kexec_loaded before rebooting", .{});
    }
    if (!try loaded(a, io)) return error.KexecLoadNotConfirmed;
    marker.status = .loaded;
    try session.writeMarker(a, io, home, marker, false);
    std.log.info("PIZZA_TRANSITION_LOADED: kernel confirmed; requesting orderly systemd kexec", .{});
    _ = try utils.process.checkedOutput(a, io, env, &.{ "systemctl", "--no-ask-password", "kexec" });
}
