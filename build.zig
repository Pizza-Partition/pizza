const std = @import("std");
const webui_build = @import("zig_webui");
pub fn build(b: *std.Build) !void {
    try @import("test/windows-vm/build.zig").add(b);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_sources = @import("test/build.zig").Sources.init(b);
    const windows_lld = b.option(bool, "windows-lld", "Use LLD for Windows GNU CRT and system import libraries") orelse false;
    const dev = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "-fincremental", "--watch" });
    dev.setCwd(b.path("."));
    dev.addPassthruArgs();
    b.step("dev", "Rebuild on source changes with incremental compilation (build arguments after --)").dependOn(&dev.step);
    const clap = b.dependency("clap", .{ .target = target, .optimize = optimize }).module("clap");
    const maintenance_package = b.dependency("pizza_maintenance", .{});
    const maintenance_source = b.option([]const u8, "maintenance-source", "Local candidate maintenance release directory for cross-repository acceptance") orelse b.graph.environ_map.get("PIZZA_MAINTENANCE_SOURCE");
    const maintenance_root: std.Build.LazyPath = if (maintenance_source) |value| (if (value.len != 0) .{ .cwd_relative = value } else maintenance_package.path("")) else maintenance_package.path("");
    const protocol_root: std.Build.LazyPath = b.path("vendor/pizza-protocol");
    const proto = b.createModule(.{ .root_source_file = protocol_root.path(b, "root.zig"), .target = target, .optimize = optimize });
    const protocol_bindings = b.addInstallDirectory(.{ .source_dir = protocol_root.path(b, "generated"), .install_dir = .prefix, .install_subdir = "share/pizza/protocol" });
    b.getInstallStep().dependOn(&protocol_bindings.step);
    b.step("protocol-bindings", "Install the locked protocol bindings for frontend tests and preview").dependOn(&protocol_bindings.step);
    const linux = if (target.result.os.tag == .linux) @import("build/linux.zig").Bindings.init(b, target, optimize) else null;
    const win32 = if (target.result.os.tag == .windows) b.dependency("win32", .{}).module("win32") else null;
    const headless = b.option(bool, "headless", "Build the backend CLI without WebUI, a WebView or embedded frontend") orelse false;
    const webui = if (headless) null else b.dependency("zig_webui", .{ .target = target, .optimize = optimize, .is_static = true, .enable_tls = false });
    if (webui) |dep| if (target.result.os.tag == .linux) try @import("build/linux.zig").patch(b, dep.module("webui"));
    const module = b.createModule(.{ .root_source_file = b.path("core/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "proto", .module = proto }} });
    module.addImport("clap", clap);
    if (webui) |dep| module.addImport("webui", dep.module("webui"));
    const image_path = maintenance_root.path(b, "maint.efi");
    b.dependOnFileContents(image_path);
    const image_file = try sourcePath(b, image_path);
    const image_bytes = try image_file.root_dir.handle.readFileAlloc(b.graph.io, image_file.sub_path, b.allocator, .limited(512 * 1024 * 1024));
    if (image_bytes.len == 0 or image_bytes.len % 4096 != 0) return error.MaintenanceImageMustBeBlockAligned;
    var image_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image_bytes, &image_digest, .{});
    const install_image = b.addInstallFileWithDir(image_path, .bin, "maint.efi");
    b.getInstallStep().dependOn(&install_image.step);
    const maintenance_files = b.addInstallDirectory(.{ .source_dir = maintenance_root, .install_dir = .prefix, .install_subdir = "share/pizza/maintenance" });
    const maintenance_step = b.step("maintenance-files", "Install the pinned maintenance release for VM acceptance");
    maintenance_step.dependOn(&maintenance_files.step);
    const configuration = b.addOptions();
    configuration.addOption(bool, "headless", headless);
    configuration.addOption([32]u8, "maintenance_image_digest", image_digest);
    module.addOptions("build_options", configuration);
    if (linux) |bindings| {
        bindings.addTo(module);
        if (!headless) module.addImport("gobject", bindings.gobject);
    }
    if (win32) |m| module.addImport("win32", m);
    if (!headless) try webui_build.addEmbeddedDir(b, module, .{ .path = "ui/partition/app", .http_responses = false });
    const exe = b.addExecutable(.{ .name = if (headless) "pizza-backend" else "pizza", .root_module = module });
    configureCompile(exe, windows_lld);
    b.installArtifact(exe);
    if (!headless and target.result.os.tag == .linux) {
        b.installFile("packaging/linux/pizza.desktop", "share/applications/pizza.desktop");
        b.installFile("ui/partition/app/assets/pizza-mark.svg", "share/icons/hicolor/scalable/apps/pizza.svg");
    }
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run Pizza").dependOn(&run.step);
    b.step("host", "Build the desktop/privileged executable into the output directory").dependOn(b.getInstallStep());
    const tests = b.addTest(.{ .name = "host-tests", .root_module = b.createModule(.{ .root_source_file = test_sources.root("host.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "proto", .module = proto }} }) });
    configureCompile(tests, windows_lld);
    tests.root_module.addImport("clap", clap);
    // Embed build-input evidence so staged tests do not depend on paths from
    // the machine that cross-compiled them.
    tests.root_module.addOptions("protocol_package", try protocolEvidence(b, protocol_root));
    if (linux) |bindings| bindings.addTo(tests.root_module);
    if (win32) |m| tests.root_module.addImport("win32", m);
    const test_run = b.addRunArtifact(tests);
    const domain = b.addTest(.{ .name = "domain-tests", .root_module = b.createModule(.{ .root_source_file = test_sources.root("domain.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "proto", .module = proto }, .{ .name = "clap", .module = clap } } }) });
    configureCompile(domain, windows_lld);
    b.step("test-domain", "Run planning, execution and application tests without system or WebUI dependencies").dependOn(&b.addRunArtifact(domain).step);

    const vm_tests = b.addTest(.{ .name = "vm-common-tests", .root_module = b.createModule(.{ .root_source_file = test_sources.files.addCopyFile(b.path("test/vm/guest.zig"), "shared-guest-tests.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "proto", .module = proto }, .{ .name = "vm_common", .module = b.createModule(.{ .root_source_file = b.path("test/vm/common.zig"), .target = target, .optimize = optimize }) } } }) });
    configureCompile(vm_tests, windows_lld);
    b.step("test-vm-common", "Check shared VM acceptance postconditions without a VM").dependOn(&b.addRunArtifact(vm_tests).step);
    if (linux) |bindings| {
        const images = b.addTest(.{ .name = "linux-image-tests", .root_module = b.createModule(.{ .root_source_file = test_sources.root("linux-image.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
        configureCompile(images, windows_lld);
        images.root_module.addImport("libc", bindings.libc);
        images.root_module.addImport("libblockdev", bindings.libblockdev);
        images.root_module.addImport("proto", proto);
        b.step("test-host-image", "Exercise system libblockdev on temporary regular-file images without root").dependOn(&b.addRunArtifact(images).step);
        const guest_sources = b.addWriteFiles();
        _ = guest_sources.addCopyDirectory(b.path("core"), "core", .{});
        _ = guest_sources.addCopyFile(b.path("test/vm/guest.zig"), "shared_guest.zig");
        const guest = b.addExecutable(.{ .name = "linux-vm-guest", .root_module = b.createModule(.{ .root_source_file = guest_sources.addCopyFile(b.path("test/linux-vm/guest.zig"), "guest.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "proto", .module = proto }, .{ .name = "vm_common", .module = b.createModule(.{ .root_source_file = b.path("test/vm/common.zig"), .target = target, .optimize = optimize }) } } }) });
        bindings.addTo(guest.root_module);
        configureCompile(guest, false);
        const stage = b.step("stage-linux-tests", "Stage Linux product and guest test binaries for QEMU");
        stage.dependOn(b.getInstallStep());
        stage.dependOn(&b.addInstallArtifact(guest, .{}).step);
        inline for (.{ .{ tests, "host" }, .{ domain, "domain" }, .{ images, "image" } }) |entry| stage.dependOn(&b.addInstallArtifact(entry[0], .{ .dest_sub_path = "linux-tests/" ++ entry[1] ++ "-tests" }).step);
    }
    const protocol_compile = b.addTest(.{ .name = "protocol-tests", .root_module = proto });
    configureCompile(protocol_compile, windows_lld);
    const protocol_tests = b.addRunArtifact(protocol_compile);
    if (linux != null) b.top_level_steps.get("stage-linux-tests").?.step.dependOn(&b.addInstallArtifact(protocol_compile, .{ .dest_sub_path = "linux-tests/protocol-tests" }).step);
    try @import("test/linux-vm/build.zig").add(b);

    b.step("test", "Run host planner and backend tests").dependOn(&test_run.step);
    b.top_level_steps.get("test").?.step.dependOn(&protocol_tests.step);
    b.step("test-host", "Run host planner and backend tests").dependOn(&test_run.step);
    b.top_level_steps.get("test-host").?.step.dependOn(&protocol_tests.step);
    b.step("check", "Compile the application and run host tests").dependOn(&test_run.step);
    b.top_level_steps.get("check").?.step.dependOn(&protocol_tests.step);
    b.top_level_steps.get("check").?.step.dependOn(&exe.step);
    b.top_level_steps.get("check").?.step.dependOn(&protocol_bindings.step);
    const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("core"), b.path("build"), b.path("test") }, .check = true });
    b.step("fmt-check", "Check Zig source formatting").dependOn(&fmt.step);
    b.step("compile", "Compile the application and host tests without running them").dependOn(&exe.step);
    b.top_level_steps.get("compile").?.step.dependOn(&vm_tests.step);
    b.top_level_steps.get("compile").?.step.dependOn(&tests.step);
    if (win32) |m| {
        const guest_sources = b.addWriteFiles();
        _ = guest_sources.addCopyDirectory(b.path("core"), "core", .{});
        _ = guest_sources.addCopyFile(b.path("test/vm/guest.zig"), "shared_guest.zig");
        const guest_source = guest_sources.addCopyFile(b.path("test/windows-vm/guest.zig"), "guest.zig");
        _ = guest_sources.addCopyFile(b.path("test/windows-vm/agent.zig"), "agent.zig");
        _ = guest_sources.addCopyFile(b.path("test/windows-vm/agent_protocol.zig"), "agent_protocol.zig");
        _ = guest_sources.addCopyFile(b.path("test/windows-vm/servicing.zig"), "servicing.zig");
        _ = guest_sources.addCopyFile(b.path("test/windows-vm/cli.zig"), "cli.zig");
        const guest = b.addExecutable(.{ .name = "windows-vm-guest", .root_module = b.createModule(.{ .root_source_file = guest_source, .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "proto", .module = proto }, .{ .name = "win32", .module = m }, .{ .name = "vm_common", .module = b.createModule(.{ .root_source_file = b.path("test/vm/common.zig"), .target = target, .optimize = optimize }) } } }) });
        configureCompile(guest, windows_lld);
        // LLD's CodeView/PDB metadata changes between clean builds. The frozen
        // baseline is bound to this executable's bytes, so omit debug metadata.
        guest.root_module.strip = true;
        guest.root_module.addImport("clap", clap);
        const images = b.addTest(.{ .name = "windows-image-tests", .root_module = b.createModule(.{ .root_source_file = test_sources.root("windows-image.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "proto", .module = proto }, .{ .name = "win32", .module = m } } }) });
        configureCompile(images, windows_lld);
        b.top_level_steps.get("compile").?.step.dependOn(&images.step);
        b.step("test-windows-image", "Run elevated Windows acceptance on a private temporary VHDX only").dependOn(&b.addRunArtifact(images).step);
        const stage = b.step("stage-windows-tests", "Stage Windows test binaries for running in a VM without Zig");
        stage.dependOn(&b.addInstallArtifact(guest, .{}).step);
        stage.dependOn(b.getInstallStep());
        inline for (.{ .{ tests, "host-tests.exe" }, .{ domain, "domain-tests.exe" }, .{ protocol_compile, "protocol-tests.exe" }, .{ images, "image-tests.exe" } }) |entry| {
            stage.dependOn(&b.addInstallArtifact(entry[0], .{ .dest_sub_path = "windows-tests/" ++ entry[1] }).step);
        }
    }
}

fn configureCompile(compile: *std.Build.Step.Compile, windows_lld: bool) void {
    compile.incremental = true;
    switch (compile.rootModuleTarget().os.tag) {
        .windows => {
            // With the pinned Zig, LLVM + native COFF leaves CRT/Win32 symbols
            // unresolved even without WebUI/zigwin32. See docs/windows-backend.md.
            compile.use_lld = windows_lld;
            compile.incremental = !windows_lld;
        },
        .linux => {
            compile.use_lld = false;
            compile.use_new_linker = true; // Zig's Elf2.zig linker.
        },
        else => {},
    }
}

fn protocolEvidence(b: *std.Build, root: std.Build.LazyPath) !*std.Build.Step.Options {
    const options = b.addOptions();
    const base = try sourcePath(b, root);
    const manifest_file = try base.join(b.allocator, "manifest.json");
    const manifest_path = root.path(b, "manifest.json");
    b.dependOnFileContents(manifest_path);
    const manifest_bytes = try manifest_file.root_dir.handle.readFileAlloc(b.graph.io, manifest_file.sub_path, b.allocator, .limited(65536));
    const Manifest = struct { wire_version: u16, source: []const u8, files: []const struct { name: []const u8, sha256: []const u8 } };
    const manifest = try std.json.parseFromSliceLeaky(Manifest, b.allocator, manifest_bytes, .{});
    const names = try b.allocator.alloc([]const u8, manifest.files.len);
    const hashes = try b.allocator.alloc([]const u8, manifest.files.len);
    for (manifest.files, 0..) |file, i| {
        if (std.fs.path.isAbsolute(file.name) or std.mem.indexOf(u8, file.name, "..") != null) return error.InvalidManifestPath;
        const path = root.path(b, file.name);
        b.dependOnFileContents(path);
        const input = try base.join(b.allocator, file.name);
        const bytes = try input.root_dir.handle.readFileAlloc(b.graph.io, input.sub_path, b.allocator, .limited(16 * 1024 * 1024));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        names[i] = file.name;
        hashes[i] = try b.allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    }
    options.addOption([]const u8, "manifest", manifest_bytes);
    options.addOption([]const []const u8, "names", names);
    options.addOption([]const []const u8, "hashes", hashes);
    return options;
}

fn sourcePath(b: *std.Build, path: std.Build.LazyPath) !std.Build.Cache.Path {
    return switch (path) {
        .dependency => |d| try d.dependency.builder.root.join(b.allocator, d.sub_path),
        .src_path => |src| try src.owner.root.join(b.allocator, src.sub_path),
        .cwd_relative => |value| .initCwd(value),
        else => error.UnsupportedProtocolSource,
    };
}
