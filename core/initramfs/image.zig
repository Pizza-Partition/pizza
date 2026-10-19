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
    const meta = try utils.elf.metadata(allocator, io, maint);
    if (meta.interp.len != 0 or meta.needed.len != 0)
        return error.Pid1MustBeStatic;
    const kernel = options.kernel_version orelse std.mem.trim(
        u8,
        try utils.process.checkedOutput(allocator, io, environ, &.{ "uname", "-r" }),
        " \t\r\n",
    );
    std.Io.Dir.cwd().access(io, try std.fs.path.join(
        allocator,
        &.{ "/lib/modules", kernel },
    ), .{}) catch return error.MatchingKernelModulesMissing;
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
    const command = try allocator.dupe([]const u8, &.{
        "dracut",
        "--tmpdir",
        temporary,
        "--conf",
        "/dev/null",
        "--confdir",
        conf,
        "--modules",
        "pizza-maint",
        "--no-hostonly",
        "--no-hostonly-cmdline",
        "--no-early-microcode",
        // Include the verified runtime after dracut's host dependency
        // resolution. Re-resolving the runtime interpreter would import host paths.
        "--include",
        root,
        "/opt/pizza/bundle",
        "--include",
        panel,
        "/opt/pizza/panel",
        // Preserve the published runtime and kernel module signatures.
        "--nostrip",
        "--gzip",
        "--kver",
        kernel,
        "--force",
        output,
    });
    if (options.dry_run) return command;
    var environment = try environ.clone(allocator);
    try environment.put("dracutbasedir", base);
    try environment.put("PIZZA_BUNDLE_ROOT", root);
    try environment.put("PIZZA_MAINT_BINARY", maint);
    try environment.put("PIZZA_PANEL_ROOT", panel);
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
