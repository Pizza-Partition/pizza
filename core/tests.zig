const std = @import("std");
const proto = @import("proto");
const power = @import("power");

test "all subsystem boundaries compile" {
    std.testing.refAllDecls(@import("transition/image.zig"));
    std.testing.refAllDecls(@import("transition/state.zig"));
    std.testing.refAllDecls(@import("transition/report.zig"));
    std.testing.refAllDecls(@import("init/cmdline.zig"));
    std.testing.refAllDecls(@import("init/mounts.zig"));
    std.testing.refAllDecls(@import("init/modules.zig"));
    std.testing.refAllDecls(@import("init/supervisor.zig"));
    std.testing.refAllDecls(@import("journal"));
    std.testing.refAllDecls(@import("maintenance").bridge);
    std.testing.refAllDecls(@import("maintenance").plan);
    std.testing.refAllDecls(@import("execution_tui"));
    std.testing.refAllDecls(proto);
}

test "transition preflight requires concrete inputs before privileged work" {
    const kexec = @import("transition/kexec.zig");
    try std.testing.expectError(error.MissingKernel, kexec.staged(std.testing.allocator, std.testing.io, .{}));
    std.testing.refAllDecls(@import("session"));
    std.testing.refAllDecls(@import("session").storage);
    try std.testing.expectError(error.NotPid1, power.poweroff());
}
