//! Native C bindings, separated by the library that owns each API.
//! Keep GLib declarations from libblockdev's headers in that translation unit:
//! its GError and related types must have the same Zig identity as the BD API.
const std = @import("std");
const Bindings = @This();

libc: *std.Build.Module,
libblockdev: *std.Build.Module,
libblkid: *std.Build.Module,
libsystemd: *std.Build.Module,
gobject: *std.Build.Module,

pub fn init(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) Bindings {
    const libc = translate(b, target, optimize, "libc.h",
        \\#define _GNU_SOURCE
        \\#include <dirent.h>
        \\#include <errno.h>
        \\#include <fcntl.h>
        \\#include <linux/fs.h>
        \\#include <linux/magic.h>
        \\#include <poll.h>
        \\#include <signal.h>
        \\#include <stdlib.h>
        \\#include <stdio.h>
        \\#include <sys/time.h>
        \\#include <sys/file.h>
        \\#include <sys/ioctl.h>
        \\#include <sys/mount.h>
        \\#include <sys/statfs.h>
        \\#include <sys/random.h>
        \\#include <sys/socket.h>
        \\#include <sys/stat.h>
        \\#include <sys/statvfs.h>
        \\#include <sys/un.h>
        \\#include <sys/wait.h>
        \\#include <unistd.h>
    );
    const blockdev = translate(b, target, optimize, "libblockdev.h",
        \\#include <blockdev/blockdev.h>
        \\#include <blockdev/fs.h>
        \\#include <blockdev/part.h>
    );
    const dep = b.dependency("libblockdev", .{});
    const headers = b.addWriteFiles();
    for ([_][]const u8{ "src/lib", "src/utils", "src/plugins" }) |dir|
        _ = headers.addCopyDirectory(dep.path(dir), "blockdev", .{ .include_extensions = &.{".h"} });
    blockdev.addIncludePath(headers.getDirectory());
    for ([_][]const u8{ "blockdev", "glib-2.0" }) |lib|
        blockdev.linkSystemLibrary(lib, .{ .use_pkg_config = .force });

    const blkid = translate(b, target, optimize, "libblkid.h",
        \\#include <blkid/blkid.h>
    );
    blkid.linkSystemLibrary("blkid", .{ .use_pkg_config = .force });
    const systemd = translate(b, target, optimize, "libsystemd.h",
        \\#include <systemd/sd-device.h>
    );
    systemd.linkSystemLibrary("libsystemd", .{ .use_pkg_config = .force });
    const gobject = translate(b, target, optimize, "gobject.h",
        \\#include <glib-object.h>
    );
    gobject.linkSystemLibrary("gobject-2.0", .{ .use_pkg_config = .force });
    return .{ .libc = libc.createModule(), .libblockdev = blockdev.createModule(), .libblkid = blkid.createModule(), .libsystemd = systemd.createModule(), .gobject = gobject.createModule() };
}

/// Backend dependencies; desktop consumers add GObject separately.
pub fn addTo(self: Bindings, module: *std.Build.Module) void {
    module.addImport("libc", self.libc);
    module.addImport("libblockdev", self.libblockdev);
    module.addImport("libblkid", self.libblkid);
    module.addImport("libsystemd", self.libsystemd);
}

fn translate(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, name: []const u8, source: []const u8) *std.Build.Step.TranslateC {
    const header = b.addWriteFiles().add(name, source);
    return b.addTranslateC(.{ .root_source_file = header, .target = target, .optimize = optimize });
}
