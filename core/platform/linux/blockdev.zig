//! Host policy in Zig; libblockdev supplies filesystem and partition algorithms.
const std = @import("std");
const libc = @import("libc");
const bd = @import("libblockdev");
const wire = @import("proto").wire;
threadlocal var error_buffer: [2048]u8 = undefined;
threadlocal var error_length: usize = 0;

pub fn init() error{NativeInitializationFailed}!void {
    error_length = 0;
    // libblockdev synchronizes initialization and checks already loaded plugins.
    var part: bd.BDPluginSpec = .{ .name = bd.BD_PLUGIN_PART, .so_name = null };
    var fs: bd.BDPluginSpec = .{ .name = bd.BD_PLUGIN_FS, .so_name = null };
    var plugins = [_][*c]bd.BDPluginSpec{ &part, &fs, null };
    var err: [*c]bd.GError = null;
    defer bd.g_clear_error(&err);
    if (bd.bd_ensure_init(&plugins, null, &err) == 0) {
        message(if (err != null) std.mem.span(err.*.message) else "libblockdev initialization failed");
        return error.NativeInitializationFailed;
    }
}

pub fn lastError() []const u8 {
    return error_buffer[0..error_length];
}

fn message(value: []const u8) void {
    error_length = @min(value.len, error_buffer.len);
    @memcpy(error_buffer[0..error_length], value[0..error_length]);
}

fn failed(err: [*c]bd.GError) error{NativeOperationFailed} {
    if (err != null) message(std.mem.span(err.*.message)) else if (error_length == 0) message("operation conditions are not satisfied");
    return error.NativeOperationFailed;
}

pub fn validLabel(fs: [:0]const u8, label: [:0]const u8) !bool {
    try init();
    var err: [*c]bd.GError = null;
    defer bd.g_clear_error(&err);
    return bd.bd_fs_check_label(fs, label, &err) != 0;
}

pub fn canFs(fs: [:0]const u8, op: wire.IntentKind, mounted: bool, shrinking: bool) !bool {
    try init();
    var err: [*c]bd.GError = null;
    defer bd.g_clear_error(&err);
    var utility: [*c]u8 = null;
    defer bd.g_free(utility);
    switch (op) {
        .create, .format => {
            var options: bd.BDFSMkfsOptionsFlags = 0;
            return !mounted and bd.bd_fs_can_mkfs(fs, &options, &utility, &err) != 0;
        },
        .label => return (mounted or !std.mem.eql(u8, fs, "btrfs")) and bd.bd_fs_can_set_label(fs, &utility, &err) != 0,
        .resize => {
            if (mounted and shrinking or !mounted and (std.mem.eql(u8, fs, "btrfs") or std.mem.eql(u8, fs, "xfs"))) return false;
            var mode: bd.BDFSResizeFlags = 0;
            const need: bd.BDFSResizeFlags = if (shrinking)
                (if (mounted) bd.BD_FS_ONLINE_SHRINK else bd.BD_FS_OFFLINE_SHRINK)
            else
                (if (mounted) bd.BD_FS_ONLINE_GROW else bd.BD_FS_OFFLINE_GROW);
            return bd.bd_fs_can_resize(fs, &mode, &utility, &err) != 0 and mode & need != 0;
        },
        else => return false,
    }
}
/// Whole-plan preflight is read-only. Execution repeats it at the step.
pub fn preflightShrink(part: [:0]const u8, fs: [:0]const u8, length: u64, mounted: bool) !void {
    try init();
    if (mounted) {
        message("online shrink has no volume-health preflight; use maintenance");
        return error.HostPreflightFailed;
    }
    var err: [*c]bd.GError = null;
    defer bd.g_clear_error(&err);
    if (bd.bd_fs_check(part, fs, &err) == 0) {
        if (err != null) message(std.mem.span(err.*.message));
        return error.HostPreflightFailed;
    }
    const minimum = bd.bd_fs_get_min_size(part, fs, &err);
    if (err != null) {
        if (err != null) message(std.mem.span(err.*.message));
        return error.HostPreflightFailed;
    }
    if (minimum == 0 or length < minimum) {
        message("requested size is below the filesystem minimum or minimum is unknown");
        return error.HostPreflightFailed;
    }
}
fn guidText(value: [:0]const u8, buffer: *[37]u8) ![:0]const u8 {
    if (value.len != 32) return value;
    const b = try @import("../../planning/identity.zig").guid(value);
    return std.mem.printSentinel(buffer, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15] }, 0);
}
pub const Operation = struct {
    disk: [:0]const u8,
    part: [:0]const u8,
    kind: wire.IntentKind,
    filesystem: [:0]const u8,
    label: [:0]const u8 = "",
    uuid: [:0]const u8 = "",
    type_guid: [:0]const u8 = "",
    offset: u64 = 0,
    length: u64 = 0,
    mounted: bool = false,
};
pub fn perform(op: Operation) !void {
    try init();
    // Hold the lease across this operation's filesystem and partition calls.
    // The library's internal lock covers table publication only and is best effort.
    const fd = libc.open(op.disk, libc.O_RDONLY | libc.O_CLOEXEC);
    if (fd < 0) {
        message("device busy or unavailable");
        return error.NativeOperationFailed;
    }
    defer _ = libc.close(fd);
    if (libc.flock(fd, libc.LOCK_EX | libc.LOCK_NB) != 0) {
        message("device busy or unavailable");
        return error.NativeOperationFailed;
    }
    defer _ = libc.flock(fd, libc.LOCK_UN);
    var err: [*c]bd.GError = null;
    defer bd.g_clear_error(&err);
    switch (op.kind) {
        .delete => {
            if (op.mounted or bd.bd_part_delete_part(op.disk, op.part, &err) == 0) return failed(err);
        },
        .label => {
            if (bd.bd_fs_check_label(op.filesystem, op.label, &err) == 0 or !op.mounted and std.mem.eql(u8, op.filesystem, "btrfs")) return failed(err);
            if (bd.bd_fs_set_label(op.part, op.label, op.filesystem, &err) == 0) return failed(err);
        },
        .create, .format => {
            if (op.mounted or bd.bd_fs_check_label(op.filesystem, op.label, &err) == 0) return failed(err);
            var created: [*c]bd.BDPartSpec = null;
            defer if (created != null) bd.bd_part_spec_free(created);
            var target: [*c]const u8 = op.part;
            if (op.kind == .create) {
                created = bd.bd_part_create_part(op.disk, bd.BD_PART_TYPE_REQ_NORMAL, op.offset, op.length, bd.BD_PART_ALIGN_NONE, &err);
                if (created == null) return failed(err);
                if (created.*.start != op.offset or created.*.size != op.length) {
                    message("created geometry differs; recheck required");
                    return failed(err);
                }
                target = created.*.path;
                var uuid_buffer: [37]u8 = undefined;
                var type_buffer: [37]u8 = undefined;
                if (bd.bd_part_set_part_uuid(op.disk, target, try guidText(op.uuid, &uuid_buffer), &err) == 0 or
                    bd.bd_part_set_part_type(op.disk, target, try guidText(op.type_guid, &type_buffer), &err) == 0) return failed(err);
            }
            const features = bd.bd_fs_features(op.filesystem, &err);
            if (features == null) return failed(err);
            var options: bd.BDFSMkfsOptions = std.mem.zeroes(bd.BDFSMkfsOptions);
            options.label = op.label;
            options.no_discard = @intFromBool(features.*.mkfs & bd.BD_FS_MKFS_NODISCARD != 0);
            options.force = 1;
            if (bd.bd_fs_mkfs(target, op.filesystem, &options, null, &err) == 0) return failed(err);
        },
        .resize => {
            const before = bd.bd_part_get_part_spec(op.disk, op.part, &err);
            if (before == null) return failed(err);
            const old = before.*.size;
            bd.bd_part_spec_free(before);
            if (!try canFs(op.filesystem, .resize, op.mounted, op.length < old)) return failed(err);
            if (op.length < old) {
                if (!op.mounted and bd.bd_fs_check(op.part, op.filesystem, &err) == 0) return failed(err);
                const minimum = bd.bd_fs_get_min_size(op.part, op.filesystem, &err);
                if (err != null or minimum == 0 or minimum > op.length) return failed(err);
                if (bd.bd_fs_resize(op.part, op.length, op.filesystem, &err) == 0 or
                    bd.bd_part_resize_part(op.disk, op.part, op.length, bd.BD_PART_ALIGN_NONE, &err) == 0) return failed(err);
            } else {
                if (bd.bd_part_resize_part(op.disk, op.part, op.length, bd.BD_PART_ALIGN_NONE, &err) == 0) return failed(err);
                const after = bd.bd_part_get_part_spec(op.disk, op.part, &err);
                if (after == null) return failed(err);
                const matches = after.*.size == op.length;
                bd.bd_part_spec_free(after);
                if (!matches) return failed(err);
                const partfd = libc.open(op.part, libc.O_RDONLY | libc.O_CLOEXEC);
                if (partfd < 0) return failed(err);
                defer _ = libc.close(partfd);
                var actual: u64 = 0;
                if (libc.ioctl(partfd, libc.BLKGETSIZE64, &actual) != 0 or actual != op.length) return failed(err);
                if (bd.bd_fs_resize(op.part, op.length, op.filesystem, &err) == 0) return failed(err);
            }
        },
        else => return failed(err),
    }
}

test "GUID conversion preserves the GPT on-disk byte order" {
    var buffer: [37]u8 = undefined;
    try std.testing.expectEqualStrings("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", try guidText("28732ac11ff8d211ba4b00a0c93ec93b", &buffer));
}
