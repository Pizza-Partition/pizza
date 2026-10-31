const std = @import("std");
pub fn add(b: *std.Build) !void {
    if (b.graph.host.result.os.tag != .linux) return;
    const common = b.createModule(.{ .root_source_file = b.path("test/vm/common.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const clap = b.dependency("clap", .{ .target = b.graph.host, .optimize = .ReleaseSafe }).module("clap");
    const artifacts = b.addExecutable(.{ .name = "build-windows-vm-artifacts", .root_module = b.createModule(.{ .root_source_file = b.path("test/windows-vm/artifacts.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    artifacts.root_module.addImport("clap", clap);
    artifacts.root_module.addImport("vm_common", common);
    const artifact_options = b.addOptions();
    artifact_options.addOption([]const u8, "root", try b.root.joinString(b.allocator, "."));
    artifact_options.addOption([]const u8, "zig", b.graph.zig_exe);
    artifacts.root_module.addOptions("artifact_options", artifact_options);
    const artifact_run = b.addRunArtifact(artifacts);
    artifact_run.addPassthruArgs();
    artifact_run.has_side_effects = true;
    b.step("build-windows-vm-artifacts", "Build matching maintenance and native Windows VM artifacts").dependOn(&artifact_run.step);
    const fetch = b.addExecutable(.{ .name = "fetch-windows-image", .root_module = b.createModule(.{ .root_source_file = b.path("test/windows-vm/fetch_image.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    fetch.root_module.addImport("clap", clap);
    fetch.root_module.addImport("vm_common", common);
    const fetch_run = b.addRunArtifact(fetch);
    fetch_run.addPassthruArgs();
    fetch_run.has_side_effects = true;
    b.step("fetch-windows-image", "Download and verify the configured Windows test ISO").dependOn(&fetch_run.step);
    const config_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/windows-vm/image_config.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    b.step("test-vm-config", "Validate VM image configuration and pinned downloads").dependOn(&b.addRunArtifact(config_tests).step);
    const download_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/windows-vm/fetch_image.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    download_tests.root_module.addImport("clap", clap);
    download_tests.root_module.addImport("vm_common", common);
    b.step("test-vm-download", "Check cached image integrity and image configuration without networking").dependOn(&b.addRunArtifact(download_tests).step);
    const cli_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/windows-vm/cli.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    cli_tests.root_module.addImport("clap", clap);
    b.step("test-vm-cli", "Check VM tool argument parsing without starting a VM").dependOn(&b.addRunArtifact(cli_tests).step);
    const serial_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/windows-vm/sac.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    b.step("test-vm-console", "Check incremental SAC parsing and command framing").dependOn(&b.addRunArtifact(serial_tests).step);
    const agent_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test/windows-vm/agent_protocol.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    agent_tests.root_module.addImport("vm_common", common);
    b.top_level_steps.get("test-vm-console").?.step.dependOn(&b.addRunArtifact(agent_tests).step);
    const step = b.step("test-windows-vm", "Run full Windows reboot and power-cut acceptance from Linux/KVM");
    const prefix = b.option([]const u8, "vm-libvirt", "Installed libvirt prefix (library and session daemon)") orelse {
        step.dependOn(&b.addFail("Pass -Dvm-libvirt=/absolute/libvirt/prefix; see test/windows-vm/README.md").step);
        return;
    };
    const api = b.lazyDependency("libvirt_api", .{}) orelse return;
    const header = b.addConfigHeader(.{ .style = .{ .autoconf_at = api.path("libvirt-12.8.0/include/libvirt/libvirt-common.h.in") }, .include_path = "libvirt/libvirt-common.h" }, .{ .LIBVIRT_VERSION_NUMBER = 12008000 });
    const c_header = b.addWriteFiles().add("vm.h",
        \\#define _DEFAULT_SOURCE
        \\#include <libvirt/libvirt.h>
        \\#include <libvirt/libvirt-qemu.h>
        \\#include <libvirt/virterror.h>
        \\#include <unistd.h>
        \\#include <stdlib.h>
    );
    const translated = b.addTranslateC(.{ .root_source_file = c_header, .target = b.graph.host, .optimize = .ReleaseSafe });
    translated.addConfigHeader(header);
    translated.addIncludePath(api.path("libvirt-12.8.0/include"));
    const runtime = b.createModule(.{ .root_source_file = b.path("test/windows-vm/vm.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .link_libc = true });
    runtime.addImport("clap", clap);
    runtime.addImport("vm_common", common);
    runtime.addImport("libvirt_c", translated.createModule());
    const module = b.createModule(.{ .root_source_file = b.path("test/windows-vm/tests.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .link_libc = true });
    module.addImport("vm_runtime", runtime);
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    module.addRPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    module.linkSystemLibrary("virt", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("virt-qemu", .{ .use_pkg_config = .no });
    const options = b.addOptions();
    options.addOption([]const u8, "libvirt_prefix", prefix);
    runtime.addOptions("vm_options", options);
    const provision_module = b.createModule(.{ .root_source_file = b.path("test/windows-vm/provision_main.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .link_libc = true });
    provision_module.addImport("vm_runtime", runtime);
    provision_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    provision_module.addRPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    provision_module.linkSystemLibrary("virt", .{ .use_pkg_config = .no });
    const provision = b.addExecutable(.{ .name = "provision-windows-vm", .root_module = provision_module });
    const provision_run = b.addRunArtifact(provision);
    provision_run.addPassthruArgs();
    provision_run.has_side_effects = true;
    b.step("provision-windows-vm", "Install the configured ISO into a new isolated Windows baseline").dependOn(&provision_run.step);
    const tests = b.addTest(.{ .name = "windows-vm", .root_module = module, .test_runner = .{ .path = b.path("test/windows-vm/runner.zig"), .mode = .simple } });
    b.step("compile-windows-vm", "Compile the Linux VM acceptance runner without starting a VM").dependOn(&tests.step);
    const run = b.addRunArtifact(tests);
    run.addPassthruArgs();
    run.has_side_effects = true;
    step.dependOn(&run.step);
}
