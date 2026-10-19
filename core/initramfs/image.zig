const std = @import("std");
const utils = @import("utils");
const bundle = @import("bundle");
const bundle_build = @import("bundle_build");
const initramfs = @import("root.zig");

pub const Options = struct {
    bundle: []const u8,
    output: []const u8,
    kernel_version: ?[]const u8 = null,
    dracut_base: ?[]const u8 = null,
    drivers: ?[]const u8 = null,
    dry_run: bool = false,
    allow_development_bundle: bool = false,
};

/// Validates the bundle and builds its dracut image; returns an allocator-owned command for reporting.
pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    checkout_root: []const u8,
    options: Options,
) ![]const []const u8 {
    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        options.bundle,
        allocator,
    );
    const output = try utils.filesystem.resolveOutputPath(
        allocator,
        io,
        checkout_root,
        options.output,
    );
    var maint: []const u8 = undefined;
    var panel: []const u8 = undefined;
    if (options.allow_development_bundle) {
        maint = try bundle.rooted(allocator, io, root, "bin/pizza-init");
        panel = try std.fs.path.join(allocator, &.{ checkout_root, "ui/execution/gui/dist" });
    } else {
        const manifest = (try bundle_build.verify(allocator, io, root)).manifest;
        const components = manifest.object.get("components").?.object;
        maint = try bundle.rooted(allocator, io, root, components.get("pizza-init").?.string);
        panel = std.fs.path.dirname(try bundle.rooted(allocator, io, root, components.get("panel-assets").?.string)) orelse return error.PanelMissing;
    }
    const maint_stat = std.Io.Dir.cwd().statFile(io, maint, .{}) catch return error.MissingExecutablePid1OrPanel;
    if (maint_stat.kind != .file)
        return error.MissingExecutablePid1OrPanel;
    std.Io.Dir.cwd().access(io, panel, .{}) catch return error.MissingExecutablePid1OrPanel;
    std.Io.Dir.cwd().access(io, maint, .{ .execute = true }) catch {
        return error.MissingExecutablePid1OrPanel;
    };
    const pid1_meta = try utils.elf.metadata(allocator, io, maint);
    if (pid1_meta.interp.len != 0 or pid1_meta.needed.len != 0)
        return error.Pid1MustBeStatic;
    var modules_root: ?[]const u8 = null;
    const kernel = if (options.allow_development_bundle)
        options.kernel_version orelse std.mem.trim(u8, try utils.process.checkedOutput(allocator, io, environ, &.{ "uname", "-r" }), " \t\r\n")
    else blk: {
        const meta = (try bundle_build.verify(allocator, io, root)).manifest;
        const pinned = meta.object.get("kernel") orelse return error.MissingKernelInventory;
        if (pinned != .object) return error.ExpectedObject;
        const value = pinned.object.get("release") orelse return error.MissingField;
        if (value != .string or !std.mem.eql(u8, value.string, "7.2.11-arch1-1")) return error.KernelModulesVersionMismatch;
        if (options.kernel_version) |selected| if (!std.mem.eql(u8, selected, value.string)) return error.KernelModulesVersionMismatch;
        modules_root = try std.fs.path.join(allocator, &.{ root, "kernel" });
        _ = try bundle.rooted(allocator, io, root, "kernel/vmlinuz");
        break :blk value.string;
    };
    const modules_path = if (modules_root) |base_root|
        try std.fs.path.join(allocator, &.{ base_root, "lib/modules", kernel })
    else
        try std.fs.path.join(allocator, &.{ "/lib/modules", kernel });
    std.Io.Dir.cwd().access(io, modules_path, .{}) catch return error.MatchingKernelModulesMissing;
    const original = (options.dracut_base orelse "/usr/lib/dracut");
    _ = try utils.process.findExecutable(allocator, io, environ, "dracut");
    std.Io.Dir.cwd().access(io, original, .{}) catch return error.DracutMissing;
    const temporary = try utils.filesystem.createTemporaryDirectory(allocator, io, "pizza-dracut-");
    defer std.Io.Dir.cwd().deleteTree(io, temporary) catch |err| std.log.warn("Cleanup {s}: {t}", .{ temporary, err });
    const base = try std.fs.path.join(allocator, &.{ temporary, "dracut" });
    try utils.process.runInherited(io, environ, &.{ "cp", "-a", "--", original, base });
    try utils.process.runInherited(
        io,
        environ,
        &.{
            "cp",
            "-a",
            "--",
            "config/dracut/90pizza-maint",
            try std.fs.path.join(
                allocator,
                &.{ base, "modules.d/90pizza-maint" },
            ),
        },
    );
    const conf = try std.fs.path.join(allocator, &.{ temporary, "conf" });
    try std.Io.Dir.cwd().createDirPath(io, conf);
    var command_list: std.array_list.Managed([]const u8) = .init(allocator);
    try command_list.appendSlice(&.{ "dracut", "--tmpdir", temporary, "--conf", "/dev/null", "--confdir", conf, "--modules", "pizza-maint", "--no-hostonly", "--no-hostonly-cmdline", "--no-early-microcode", "--nostrip", "--gzip", "--kver", kernel });
    if (modules_root != null) try command_list.appendSlice(&.{ "--kmoddir", modules_path });
    // Include only userspace here; selected kernel modules are installed separately by dracut.
    for ([_][]const u8{ "bin", "lib", "share" }) |part| {
        std.Io.Dir.cwd().access(io, try std.fs.path.join(allocator, &.{ root, part }), .{}) catch |err| {
            if (options.allow_development_bundle and err == error.FileNotFound) continue;
            return err;
        };
        try command_list.appendSlice(&.{ "--include", try std.fs.path.join(allocator, &.{ root, part }), try std.fs.path.join(allocator, &.{ bundle.prefix, part }) });
    }
    try command_list.appendSlice(&.{ "--include", panel, "/opt/pizza/panel", "--force", output });
    const command = try command_list.toOwnedSlice();
    if (options.dry_run) return command;
    var environment = try environ.clone(allocator);
    try environment.put("dracutbasedir", base);
    try environment.put("PIZZA_BUNDLE_ROOT", root);
    try environment.put("PIZZA_MAINT_BINARY", maint);
    try environment.put("PIZZA_PANEL_ROOT", panel);
    if (modules_root) |module_base| try environment.put("PIZZA_MODULES_ROOT", module_base);
    try environment.put(
        "PIZZA_DRIVERS",
        options.drivers orelse "virtio_pci virtio_blk nvme ahci ext4",
    );
    if (std.fs.path.dirname(output)) |parent|
        try std.Io.Dir.cwd().createDirPath(io, parent);
    var child = try std.process.spawn(
        io,
        .{
            .argv = command,
            .environ_map = &environment,
        },
    );
    defer child.kill(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0)
        return error.DracutFailed;
    const image = try std.Io.Dir.cwd().openFile(io, output, .{ .mode = .read_write });
    defer image.close(io);
    try image.writePositionalAll(
        io,
        try initramfs.console(allocator),
        (try image.stat(io)).size,
    );
    try image.sync(io);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try allocator.print("{s}.pizza.json", .{output}),
        .data = try std.json.Stringify.valueAlloc(allocator, .{
            .version = @as(u16, 1),
            .development = options.allow_development_bundle,
            .kernel_version = kernel,
            .image_sha256 = try utils.filesystem.hashFileSha256(allocator, io, output),
        }, .{ .whitespace = .indent_2 }),
    });
    return command;
}
