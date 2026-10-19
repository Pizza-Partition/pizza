const std = @import("std");
const binaries = @import("test_binaries");

// Run the actual executables to test command forwarding, help and exit status.
test "engineering and test commands have separate executable entry points" {
    const cases = .{
        .{ binaries.pizza, &.{ "transition", "report", "--help" }, "--journal" },
        .{ binaries.pizza, &.{ "transition", "build", "--help" }, "--journal-device" },
        .{ binaries.pizza, &.{ "transition", "transition", "--help" }, "--workspace" },
        .{ binaries.tools, &.{"--help"}, "pizza-tools" },
        .{ binaries.runner, &.{"--help"}, "pizza-tests" },
        .{ binaries.application, &.{"--help"}, "pizza-maint" },
        .{ binaries.tools, &.{ "image", "--help" }, "--bundle" },
        .{ binaries.tools, &.{ "prepare-bundle", "--help" }, "--destination" },
        .{ binaries.tools, &.{ "pack-bundle", "--help" }, "--output" },
        .{ binaries.tools, &.{ "verify-bundle", "--help" }, "--bundle" },
        .{ binaries.tools, &.{ "clean", "--help" }, "pizza-tools clean" },
        .{ binaries.runner, &.{ "smoke", "--help" }, "--kernel" },
        .{ binaries.runner, &.{ "maintenance", "--help" }, "--kernel-version" },
        .{ binaries.runner, &.{ "journal", "--help" }, "--binary" },
        .{ binaries.runner, &.{ "executor", "--help" }, "--fixture" },
        .{ binaries.runner, &.{ "kexec", "--help" }, "--maintenance-image" },
        .{ binaries.runner, &.{ "transition", "--help" }, "--journal-disk" },
        .{ binaries.runner, &.{ "matrix", "--help" }, "--binary-arg" },
    };
    inline for (cases) |case| {
        const argv = [_][]const u8{case[0]} ++ case[1].*;
        const output = try std.process.run(
            std.testing.allocator,
            std.testing.io,
            .{
                .argv = &argv,
            },
        );
        defer std.testing.allocator.free(output.stdout);
        defer std.testing.allocator.free(output.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, output.term);
        try std.testing.expect(std.mem.indexOf(u8, output.stdout, case[2]) != null);
        try std.testing.expectEqualStrings("", output.stderr);
    }
}

test "clap errors fail before fixture access and logs stay on stderr" {
    const cases = .{
        .{ binaries.pizza, &.{ "transition", "build" }, "MissingKernel" },
        .{ binaries.pizza, &.{ "transition", "build", "--kernel", "/unused" }, "MissingInitrd" },
        .{ binaries.application, &.{ "--session", "--execute" }, "SessionConflictsWithOverrides" },
        .{ binaries.application, &.{ "--session", "--plan", "/unused" }, "SessionConflictsWithOverrides" },
        .{ binaries.tools, &.{"smoke"}, "NameNotPartOfEnum" },
        .{ binaries.runner, &.{"doctor"}, "NameNotPartOfEnum" },
        .{ binaries.tools, &.{ "fmt", "--unknown" }, "InvalidArgument" },
        .{ binaries.tools, &.{ "prepare-bundle", "--source", "/unused" }, "InvalidArgument" },
        .{ binaries.tools, &.{ "prepare-bundle", "--components", "/unused" }, "InvalidArgument" },
        .{ binaries.tools, &.{ "prepare-bundle", "--loader", "/unused" }, "InvalidArgument" },
        .{ binaries.tools, &.{ "prepare-bundle", "--runtime" }, "MissingValue" },
        .{ binaries.tools, &.{"prepare-bundle"}, "MissingRuntime" },
        .{ binaries.tools, &.{ "prepare-bundle", "--runtime", "/unused" }, "MissingInitBinary" },
        .{ binaries.tools, &.{ "prepare-bundle", "--runtime", "/unused", "--init", "/unused", "--maintenance", "/unused" }, "MissingPanelAssets" },
        .{ binaries.tools, &.{ "prepare-bundle", "--runtime", "/unused", "--init", "/unused", "--maintenance", "/unused", "--panel", "/unused" }, "MissingDestination" },
        .{ binaries.runner, &.{ "smoke", "--timeout=abc" }, "InvalidCharacter" },
        .{ binaries.runner, &.{ "transition", "--timeout=-1" }, "InvalidCharacter" },
        .{ binaries.runner, &.{ "matrix", "--binary-arg" }, "MissingValue" },
        .{ binaries.application, &.{"--timeout=abc"}, "InvalidCharacter" },
        .{ binaries.application, &.{"--execute"}, "MissingExecutionPlan" },
        .{ binaries.application, &.{ "--execute", "--exit-after-plan" }, "ExitAfterPlanNeedsConsole" },
        .{ binaries.application, &.{"--step-hang=8"}, "ExecutionOptionNeedsExecute" },
        .{ binaries.application, &.{ "--execute", "--step-fail=0" }, "InvalidFaultStep" },
        .{ binaries.application, &.{ "--execute", "--step-delay-ms=60001" }, "InvalidStepDelay" },
    };
    inline for (cases) |case| {
        const argv = [_][]const u8{case[0]} ++ case[1].*;
        const output = try std.process.run(
            std.testing.allocator,
            std.testing.io,
            .{
                .argv = &argv,
            },
        );
        defer std.testing.allocator.free(output.stdout);
        defer std.testing.allocator.free(output.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, output.term);
        try std.testing.expectEqualStrings("", output.stdout);
        try std.testing.expect(std.mem.startsWith(u8, output.stderr, "error:"));
        try std.testing.expect(std.mem.indexOf(u8, output.stderr, case[2]) != null);
    }
}
