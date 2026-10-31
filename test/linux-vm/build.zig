const std = @import("std");
pub fn add(b: *std.Build) !void {
    if (b.graph.host.result.os.tag != .linux) return;
    const exe = b.addExecutable(.{ .name = "linux-vm", .root_module = b.createModule(.{ .root_source_file = b.path("test/linux-vm/host.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    exe.root_module.addImport("common", b.createModule(.{ .root_source_file = b.path("test/vm/common.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }));
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    run.has_side_effects = true;
    b.step("test-linux-vm", "Provision or run isolated Linux UEFI reboot and power-cut acceptance").dependOn(&run.step);
    b.step("compile-linux-vm", "Compile the Linux QEMU runner without starting a VM").dependOn(&exe.step);
}
