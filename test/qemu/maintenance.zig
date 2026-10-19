//! Phase 3 acceptance: boot the layered initramfs with a disposable virtio disk.
const std = @import("std");
const utils = @import("utils");
const initramfs = @import("initramfs");
const clap = @import("clap");
const h = @import("harness.zig");

const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--bridge  Boot the real WPE native bridge test instead of supervisor diagnostics.
    \\--bundle <str>  Prepared full bundle (default: zig-out/runtime/bundle).
    \\--kernel-version <str>  Matching /lib/modules version (required).
    \\--kernel <str>  Kernel path (default: /lib/modules/VERSION/vmlinuz).
    \\--output <str>  VM output directory outside the checkout.
    \\--timeout <u32>  VM timeout in seconds (default: 120).
);

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, checkout_root: []const u8, argv: []const []const u8) !void {
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var parsed = try clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{ .allocator = allocator });
    defer parsed.deinit();
    if (parsed.args.help != 0) {
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tests maintenance [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    }
    const version = parsed.args.@"kernel-version" orelse return error.MissingKernelVersion;
    try utils.filesystem.checkPath(version);
    if (std.mem.indexOfScalar(u8, version, '/') != null) return error.InvalidKernelVersion;
    const kernel = try utils.filesystem.resolveOutputPath(allocator, io, checkout_root, parsed.args.kernel orelse try allocator.print("/lib/modules/{s}/vmlinuz", .{version}));
    const kernel_stat = try std.Io.Dir.cwd().statFile(io, kernel, .{});
    if (kernel_stat.kind != .file) return error.KernelMissing;
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, parsed.args.bundle orelse "zig-out/runtime/bundle", allocator);
    const output = if (parsed.args.output) |path| try utils.filesystem.resolveOutputPath(allocator, io, checkout_root, path) else try utils.filesystem.createTemporaryDirectory(allocator, io, "pizza-qemu-maintenance-");
    if (utils.filesystem.pathIsWithin(checkout_root, output)) return error.VmArtifactsMustBeOutsideCheckout;
    try std.Io.Dir.cwd().createDirPath(io, output);
    const image = try std.fs.path.join(allocator, &.{ output, "maintenance.cpio.gz" });
    _ = try initramfs.build(allocator, io, environ, checkout_root, .{
        .bundle = root,
        .output = image,
        .kernel_version = version,
    });
    const disk = try std.fs.path.join(allocator, &.{ output, "device.raw" });
    try h.noComma(disk);
    const file = try std.Io.Dir.cwd().createFile(io, disk, .{ .exclusive = true });
    defer file.close(io);
    try file.setLength(io, 16 * 1024 * 1024);
    var command = try h.baseCommand(allocator, io, environ, output, if (parsed.args.bridge != 0) 4096 else 2048);
    try command.appendSlice(&.{
        "-nic",    "none",                                                                                                                                                                                           "-kernel", kernel,                                                                    "-initrd",    image,
        "-append", if (parsed.args.bridge != 0) "console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.boot=bridge_test" else "console=ttyS0 loglevel=4 panic=1 rdinit=/init pizza.boot=selftest pizza.kiosk=disable", "-drive",  try allocator.print("if=virtio,format=raw,readonly=on,file={s}", .{disk}), "-no-reboot",
    });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ output, "command.json" }), .data = try std.json.Stringify.valueAlloc(allocator, command.items, .{ .whitespace = .indent_2 }) });
    const serial = try h.runVm(allocator, io, environ, command.items, output, parsed.args.timeout orelse 120);
    if (parsed.args.bridge != 0) {
        const result = .{
            .ram_root = has(serial, "PIZZA_MAINT_RAM_ROOT_READY"),
            .native_bridge = has(serial, "PIZZA_BRIDGE_SELFTEST_READY"),
            .application_reaped = has(serial, "PIZZA_INIT_BRIDGE_CHILD_READY"),
            .powered_off = has(serial, "Power down"),
            .healthy = !has(serial, "Kernel panic") and !has(serial, "PIZZA_MAINT_DEGRADED") and !has(serial, "PIZZA_MAINT_PANIC"),
            .artifacts = output,
        };
        const json = try std.json.Stringify.valueAlloc(allocator, result, .{ .whitespace = .indent_2 });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ output, "results.json" }), .data = json });
        try std.Io.File.stdout().writeStreamingAll(io, json);
        if (!result.ram_root or !result.native_bridge or !result.application_reaped or !result.powered_off or !result.healthy) return error.BridgeBootFailed;
        return;
    }
    const result = .{
        .ram_root = has(serial, "PIZZA_MAINT_RAM_ROOT_READY"),
        .mounts = has(serial, "PIZZA_MAINT_MOUNTS_READY"),
        .parameters = has(serial, "PIZZA_MAINT_CMDLINE_READY: boot=selftest"),
        .modules = has(serial, "PIZZA_MAINT_MODULES_READY"),
        .bundle_cwd = has(serial, "PIZZA_MAINT_BUNDLE_CWD_READY"),
        .device = has(serial, "PIZZA_MAINT_DEVICE_READY"),
        .dynamic_program = has(serial, "PIZZA_MAINT_DYNAMIC_PROBE_READY"),
        .reaper = has(serial, "PIZZA_MAINT_REAPER_READY"),
        .application_isolated = has(serial, "PIZZA_INIT_APPLICATION_EXIT_OBSERVED"),
        .signals = has(serial, "PIZZA_MAINT_SIGNALS_READY"),
        .persistent_supervisor = has(serial, "PIZZA_MAINT_SELFTEST_READY"),
        .powered_off = has(serial, "Power down"),
        .healthy = !has(serial, "PIZZA_MAINT_DEGRADED") and !has(serial, "PIZZA_MAINT_PANIC") and !has(serial, "Kernel panic"),
        .artifacts = output,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, result, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ output, "results.json" }), .data = json });
    try std.Io.File.stdout().writeStreamingAll(io, json);
    if (!result.ram_root or !result.mounts or !result.parameters or !result.modules or !result.bundle_cwd or !result.device or !result.dynamic_program or !result.reaper or !result.application_isolated or !result.signals or !result.persistent_supervisor or !result.powered_off or !result.healthy)
        return error.MaintenanceBootFailed;
}

fn has(serial: []const u8, marker: []const u8) bool {
    return std.mem.indexOf(u8, serial, marker) != null;
}
