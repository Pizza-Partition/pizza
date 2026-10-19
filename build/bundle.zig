//! Consumes an attested pizza-bundle release and adds this checkout's application.
const std = @import("std");

pub fn add(b: *std.Build, tool: *std.Build.Step.Compile, init_binary: *std.Build.Step.Compile, maintenance: *std.Build.Step.Compile, panel: *std.Build.Step.Run) *std.Build.Step {
    const fetch = b.addSystemCommand(&.{ "node", "tools/runtime.mjs", "fetch", "--lock" });
    fetch.setCwd(b.path("."));
    fetch.addFileArg(b.path("config/bundle/release.json"));
    fetch.addFileInput(b.path("tools/runtime.mjs"));
    fetch.addArg("--destination");
    const runtime = fetch.addOutputDirectoryArg2("runtime", .{});
    const runtime_step = b.step("runtime-deps", "Download and verify the pinned pizza-bundle release");
    runtime_step.dependOn(&fetch.step);
    const prepare = b.addRunArtifact(tool);
    prepare.setCwd(b.path("."));
    prepare.addArgs(&.{ "prepare-bundle", "--runtime" });
    prepare.addDirectoryArg2(runtime, .{});
    prepare.addArg("--init");
    prepare.addArtifactArg(init_binary);
    prepare.addArg("--maintenance");
    prepare.addArtifactArg(maintenance);
    prepare.addArg("--panel");
    prepare.addDirectoryArg2(b.path("ui/execution/gui/dist"), .{});
    prepare.addArg("--destination");
    const directory = prepare.addOutputDirectoryArg2("bundle", .{});
    prepare.addFileInput(b.path("tools/runtime.mjs"));
    prepare.addFileInput(b.path("config/bundle/release.json"));
    prepare.step.dependOn(&panel.step);
    const pack = b.addRunArtifact(tool);
    pack.setCwd(b.path("."));
    pack.addArgs(&.{ "pack-bundle", "--bundle" });
    pack.addDirectoryArg2(directory, .{});
    pack.addArg("--output");
    const archive = pack.addOutputFileArg2("bundle.tar.gz", .{});
    const step = b.step("bundle", "Assemble Pizza with the verified runtime release");
    step.dependOn(&b.addInstallFileWithDir(archive, .prefix, "share/pizza/bundle.tar.gz").step);
    const copy = b.addSystemCommand(&.{ "cp", "-a" });
    copy.addDirectoryArg2(directory, .{});
    copy.addDirectoryArg2(b.graph.path(.install_prefix, "runtime/bundle"), .{});
    // Replace the previously installed tree, never merge stale dependency files.
    const remove = b.addSystemCommand(&.{ "rm", "-rf" });
    remove.addDirectoryArg2(b.graph.path(.install_prefix, "runtime/bundle"), .{});
    remove.step.dependOn(&pack.step);
    const parent = b.addSystemCommand(&.{ "mkdir", "-p" });
    parent.addDirectoryArg2(b.graph.path(.install_prefix, "runtime"), .{});
    parent.step.dependOn(&remove.step);
    copy.step.dependOn(&parent.step);
    step.dependOn(&copy.step);
    const image = b.addRunArtifact(tool);
    image.setCwd(b.path("."));
    image.addArgs(&.{ "image", "--bundle" });
    image.addDirectoryArg2(directory, .{});
    image.addArg("--output");
    const image_file = image.addOutputFileArg2("maint.img", .{});
    const image_step = b.step("image", "Build initramfs using the pinned Linux 7.2.11 modules");
    image_step.dependOn(&b.addInstallFileWithDir(image_file, .prefix, "share/pizza/maint.img").step);
    image_step.dependOn(&b.addInstallFileWithDir(image_file.dirname().path(b, "maint.img.pizza.json"), .prefix, "share/pizza/maint.img.pizza.json").step);
    image_step.dependOn(&b.addInstallFileWithDir(directory.path(b, "kernel/vmlinuz"), .prefix, "share/pizza/vmlinuz").step);
    return step;
}
