const std = @import("std");
const bundle_steps = @import("build/bundle.zig");

/// Registers core binaries, engineering commands, format checks and test suites.
/// Host tools use the baseline Linux target; core binaries use the selected build target.
pub fn build(b: *std.Build) void {
    const npm = requireHostTool(b, "NPM", "npm");
    _ = requireHostTool(b, "NODE", "node");
    // TODO: Support for other OSes.
    const target = b.standardTargetOptions(
        .{
            .default_target = .{
                .cpu_arch = .x86_64,
                .cpu_model = .baseline,
                .os_tag = .linux,
                .os_version_min = .{
                    .semver = .{ .major = 4, .minor = 18, .patch = 0 },
                },
                .abi = .musl,
            },
        },
    );

    const optimize = b.standardOptimizeOption(.{});
    const host_target = b.resolveTargetQuery(
        .{
            .cpu_arch = .x86_64,
            .cpu_model = .baseline,
            .os_tag = .linux,
            .os_version_min = .{
                .semver = .{ .major = 4, .minor = 18, .patch = 0 },
            },
            .abi = .musl,
        },
    );
    // 3rd parties
    const clap = b.dependency("clap", .{ .target = host_target, .optimize = .safe });
    const core_clap = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const core_utils = b.createModule(.{
        .root_source_file = b.path("core/utils/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const utils = b.addModule(
        "utils",
        .{
            .root_source_file = b.path("core/utils/root.zig"),
            .target = host_target,
            .optimize = .safe,
        },
    );
    const bundle = b.addModule("bundle", .{
        .root_source_file = b.path("core/bundle/root.zig"),
        .target = host_target,
        .optimize = .safe,
        .imports = &.{.{ .name = "utils", .module = utils }},
    });
    const core_bundle = b.createModule(.{
        .root_source_file = b.path("core/bundle/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "utils", .module = core_utils }},
    });
    const bundle_build = b.addModule("bundle_build", .{
        .root_source_file = b.path("build/bundle/root.zig"),
        .target = host_target,
        .optimize = .safe,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "bundle", .module = bundle },
        },
    });
    const initramfs = b.addModule("initramfs", .{
        .root_source_file = b.path("core/initramfs/root.zig"),
        .target = host_target,
        .optimize = .safe,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "bundle", .module = bundle },
            .{ .name = "bundle_build", .module = bundle_build },
        },
    });
    const vm = b.addModule(
        "vm",
        .{
            .root_source_file = b.path("test/qemu/root.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "utils", .module = utils },
                .{ .name = "bundle_build", .module = bundle_build },
                .{ .name = "initramfs", .module = initramfs },
                .{ .name = "clap", .module = clap.module("clap") },
            },
        },
    );
    const matrix = b.addModule(
        "matrix",
        .{
            .root_source_file = b.path("test/matrix/run.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "utils", .module = utils },
                .{ .name = "bundle", .module = bundle },
                .{ .name = "bundle_build", .module = bundle_build },
                .{ .name = "vm", .module = vm },
                .{ .name = "clap", .module = clap.module("clap") },
            },
        },
    );
    const tool = b.addExecutable(
        .{
            .name = "pizza-tools",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("tools/main.zig"),
                    .target = host_target,
                    .optimize = .safe,
                    .imports = &.{
                        .{ .name = "utils", .module = utils },
                        .{ .name = "clap", .module = clap.module("clap") },
                        .{ .name = "bundle_build", .module = bundle_build },
                        .{ .name = "initramfs", .module = initramfs },
                    },
                    .link_libc = false,
                },
            ),
        },
    );
    enableNewElfLinker(tool);
    b.installArtifact(tool);
    const runner = b.addExecutable(.{
        .name = "pizza-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "utils", .module = utils },
                .{ .name = "vm", .module = vm },
                .{ .name = "matrix", .module = matrix },
                .{ .name = "clap", .module = clap.module("clap") },
            },
            .link_libc = false,
        }),
    });
    enableNewElfLinker(runner);
    const install_tests = b.step("test-runners", "Build and install optional test executables");
    install_tests.dependOn(&b.addInstallArtifact(runner, .{}).step);
    const tools = b.addRunArtifact(tool);
    tools.setCwd(b.path("."));
    tools.addPassthruArgs();
    b.step(
        "tools",
        "Run a native Zig infrastructure command (arguments after --)",
    ).dependOn(&tools.step);
    const fmt = command(b, tool, &.{"fmt"});
    b.step(
        "fmt",
        "Format Zig, JSON, frontend, docs and C sources",
    ).dependOn(&fmt.step);
    const fmt_check = command(b, tool, &.{ "fmt", "--check" });
    b.step(
        "fmt-check",
        "Check formatting without modifying files",
    ).dependOn(&fmt_check.step);
    const web_deps = b.addSystemCommand(
        &.{
            npm,
            "--prefix",
            "ui",
            "ci",
            "--include=dev",
            "--engine-strict",
            "--ignore-scripts",
            "--no-audit",
            "--no-fund",
        },
    );

    const deps = b.step(
        "deps",
        "Install locked developer and formatter dependencies",
    );
    deps.dependOn(&web_deps.step);
    const check = command(b, tool, &.{ "proto", "--check" });
    const proto = b.addModule(
        "proto",
        .{
            .root_source_file = b.path("core/proto/root.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    const power = b.addModule(
        "power",
        .{
            .root_source_file = b.path("core/power.zig"),
            .target = target,
            .optimize = optimize,
        },
    );

    const journal = b.createModule(.{
        .root_source_file = b.path("core/maint/journal.zig"),
        .target = host_target,
        .optimize = .safe,
        .imports = &.{
            .{ .name = "proto", .module = b.createModule(.{ .root_source_file = b.path("core/proto/root.zig"), .target = host_target, .optimize = .safe }) },
            .{ .name = "utils", .module = utils },
        },
    });
    const core_journal = b.createModule(.{
        .root_source_file = b.path("core/maint/journal.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "proto", .module = proto }, .{ .name = "utils", .module = core_utils } },
    });
    const core_session = sessionModule(b, target, optimize, proto, core_utils);
    vm.addImport("journal", journal);
    const journal_guest = b.addExecutable(.{
        .name = "pizza-journal-guest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/qemu/journal_guest.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "journal", .module = journal },
                .{ .name = "power", .module = power },
                .{ .name = "mounts", .module = b.createModule(.{
                    .root_source_file = b.path("core/init/mounts.zig"),
                    .target = host_target,
                    .optimize = .safe,
                    .imports = &.{.{ .name = "utils", .module = utils }},
                }) },
            },
        }),
    });
    enableNewElfLinker(journal_guest);
    install_tests.dependOn(&b.addInstallArtifact(journal_guest, .{}).step);
    const run_journal = command(b, runner, &.{ "journal", "--binary" });
    run_journal.addArtifactArg(journal_guest);
    run_journal.addPassthruArgs();
    b.step("test-journal", "Verify journal persistence across two QEMU boots").dependOn(&run_journal.step);

    var maintenance: *std.Build.Step.Compile = undefined;
    var transition_cli: *std.Build.Step.Compile = undefined;
    for ([_][2][]const u8{
        .{ "pizza", "core/transition/main.zig" },
        .{ "pizza-init", "core/init/main.zig" },
    }) |entry| {
        const exe = b.addExecutable(
            .{
                .name = entry[0],
                .root_module = b.createModule(
                    .{
                        .root_source_file = b.path(entry[1]),
                        .target = target,
                        .optimize = optimize,
                        .imports = &.{
                            .{ .name = "proto", .module = proto },
                            .{ .name = "power", .module = power },
                        },
                        .link_libc = false,
                    },
                ),
            },
        );
        enableNewElfLinker(exe);
        exe.step.dependOn(&check.step);
        exe.root_module.addImport("clap", core_clap.module("clap"));
        exe.root_module.addImport("bundle", core_bundle);
        exe.root_module.addImport("utils", core_utils);
        exe.root_module.addImport("journal", core_journal);
        exe.root_module.addImport("session", core_session);
        exe.root_module.addImport("initramfs_archive", b.createModule(.{ .root_source_file = b.path("core/initramfs/archive.zig"), .target = target, .optimize = optimize }));
        if (std.mem.eql(u8, entry[0], "pizza-init"))
            maintenance = exe
        else
            transition_cli = exe;
        b.installArtifact(exe);
    }

    const app_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .baseline,
        .os_tag = .linux,
        .os_version_min = .{ .semver = .{ .major = 4, .minor = 18, .patch = 0 } },
        .abi = .gnu,
        .glibc_version = .{ .major = 2, .minor = 28, .patch = 0 },
    });
    const app_proto = b.createModule(.{ .root_source_file = b.path("core/proto/root.zig"), .target = app_target, .optimize = optimize });
    const app_utils = b.createModule(.{ .root_source_file = b.path("core/utils/root.zig"), .target = app_target, .optimize = optimize });
    const app_session = sessionModule(b, app_target, optimize, app_proto, app_utils);
    const application = b.addExecutable(.{
        .name = "pizza-maint",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/maint/main.zig"),
            .target = app_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "proto", .module = app_proto },                                                                           .{ .name = "utils", .module = app_utils },
                .{ .name = "clap", .module = b.dependency("clap", .{ .target = app_target, .optimize = optimize }).module("clap") },
                .{ .name = "journal", .module = b.createModule(.{
                    .root_source_file = b.path("core/maint/journal.zig"),
                    .target = app_target,
                    .optimize = optimize,
                    .imports = &.{ .{ .name = "proto", .module = app_proto }, .{ .name = "utils", .module = app_utils } },
                }) },
            },
        }),
    });
    application.root_module.addImport("session", app_session);
    enableNewElfLinker(application);
    application.step.dependOn(&check.step);
    b.installArtifact(application);
    const app_ui = executionModules(b, app_target, optimize, app_proto, app_utils, application.root_module.import_table.get("journal").?, app_session);
    application.root_module.addImport("maintenance", app_ui.maintenance);
    application.root_module.addImport("execution_gui", app_ui.gui);
    application.root_module.addImport("execution_tui", app_ui.tui);
    const run_tui = command(b, application, &.{"--tui-self-test"});
    b.step("test-tui", "Verify libvaxis on a real controlling terminal").dependOn(&run_tui.step);
    const executor_guest = b.addExecutable(.{
        .name = "pizza-executor-guest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/qemu/executor_guest.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "journal", .module = journal },                                               .{ .name = "proto", .module = journal.import_table.get("proto").? },                                                                                        .{ .name = "utils", .module = utils }, .{ .name = "power", .module = power },
                .{ .name = "mounts", .module = journal_guest.root_module.import_table.get("mounts").? }, .{ .name = "supervisor", .module = b.createModule(.{ .root_source_file = b.path("core/init/supervisor.zig"), .target = host_target, .optimize = .safe }) },
            },
        }),
    });
    enableNewElfLinker(executor_guest);
    install_tests.dependOn(&b.addInstallArtifact(executor_guest, .{}).step);
    const fixture_session = sessionModule(b, host_target, .safe, journal.import_table.get("proto").?, utils);
    const kexec_guest = b.addExecutable(.{
        .name = "pizza-kexec-guest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/qemu/kexec_guest.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "session", .module = fixture_session },                                       .{ .name = "journal", .module = journal },
                .{ .name = "proto", .module = journal.import_table.get("proto").? },                     .{ .name = "utils", .module = utils },
                .{ .name = "mounts", .module = journal_guest.root_module.import_table.get("mounts").? },
            },
        }),
    });
    enableNewElfLinker(kexec_guest);
    install_tests.dependOn(&b.addInstallArtifact(kexec_guest, .{}).step);
    // Large-image hashing inside TCG is prohibitively slow in Debug. Exercise
    // the real transition CLI source with the same Safe mode as the host runner.
    const kexec_cli = b.addExecutable(.{
        .name = "pizza-kexec-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/transition/main.zig"),
            .target = host_target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "proto", .module = journal.import_table.get("proto").? },
                .{ .name = "utils", .module = utils },
                .{ .name = "journal", .module = journal },
                .{ .name = "session", .module = fixture_session },
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "initramfs_archive", .module = b.createModule(.{ .root_source_file = b.path("core/initramfs/archive.zig"), .target = host_target, .optimize = .safe }) },
            },
        }),
    });
    enableNewElfLinker(kexec_cli);
    const run_kexec = command(b, runner, &.{ "kexec", "--fixture" });
    run_kexec.addArtifactArg(kexec_guest);
    run_kexec.addArg("--binary");
    run_kexec.addArtifactArg(kexec_cli);
    run_kexec.addPassthruArgs();
    b.step("test-kexec", "Verify real systemd kexec, production journal handoff and recovery").dependOn(&run_kexec.step);
    const run_executor = command(b, runner, &.{ "executor", "--fixture" });
    run_executor.addArtifactArg(executor_guest);
    run_executor.addArg("--report-binary");
    run_executor.addArtifactArg(transition_cli);
    run_executor.addPassthruArgs();
    b.step("test-executor", "Verify live execution and persisted fault recovery in QEMU").dependOn(&run_executor.step);
    const run_bridge = command(b, application, &.{ "--self-test", "--headless", "--panel", "ui/execution/gui/dist/index.html", "--wpe-library", "/usr/lib/libWPEWebKit-2.0.so.1" });
    run_bridge.addPassthruArgs();
    b.step("test-bridge", "Run the real local panel and WPE native bridge headlessly").dependOn(&run_bridge.step);

    const tests = b.addTest(
        .{
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("core/tests.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "proto", .module = proto },
                        .{ .name = "power", .module = power },
                        .{ .name = "utils", .module = core_utils },
                    },
                },
            ),
        },
    );
    enableNewElfLinker(tests);
    tests.root_module.addImport("journal", core_journal);
    tests.root_module.addImport("session", core_session);
    tests.root_module.addImport("initramfs_archive", b.createModule(.{ .root_source_file = b.path("core/initramfs/archive.zig"), .target = target, .optimize = optimize }));
    const test_ui = executionModules(b, target, optimize, proto, core_utils, core_journal, core_session);
    tests.root_module.addImport("maintenance", test_ui.maintenance);
    tests.root_module.addImport("execution_tui", test_ui.tui);
    tests.step.dependOn(&check.step);
    const test_step = b.step(
        "test",
        "Run Zig module/integration tests and frontend tests",
    );
    test_step.dependOn(&executor_guest.step);
    test_step.dependOn(&kexec_guest.step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const utils_tests = b.addTest(.{ .root_module = utils });
    enableNewElfLinker(utils_tests);
    test_step.dependOn(&b.addRunArtifact(utils_tests).step);
    const bundle_tests = b.addTest(.{ .root_module = bundle });
    enableNewElfLinker(bundle_tests);
    const run_bundle_tests = b.addRunArtifact(bundle_tests);
    run_bundle_tests.setCwd(b.path("."));
    run_bundle_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_bundle_tests.step);
    const bundle_build_tests = b.addTest(.{ .root_module = bundle_build });
    enableNewElfLinker(bundle_build_tests);
    const run_bundle_build_tests = b.addRunArtifact(bundle_build_tests);
    run_bundle_build_tests.setCwd(b.path("."));
    run_bundle_build_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_bundle_build_tests.step);
    const archive_tests = b.addTest(.{ .root_module = initramfs });
    enableNewElfLinker(archive_tests);
    test_step.dependOn(&b.addRunArtifact(archive_tests).step);
    for ([_][]const u8{
        "test/qemu/harness.zig",
        "test/qemu/transition.zig",
    }) |source| {
        const module_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = host_target,
                .optimize = .debug,
                .imports = &.{
                    .{ .name = "utils", .module = utils },
                    .{ .name = "clap", .module = clap.module("clap") },
                },
            }),
        });
        enableNewElfLinker(module_tests);
        test_step.dependOn(&b.addRunArtifact(module_tests).step);
    }
    const matrix_tests = b.addTest(.{ .root_module = matrix });
    enableNewElfLinker(matrix_tests);
    test_step.dependOn(&b.addRunArtifact(matrix_tests).step);
    const test_binaries = b.addOptions();
    test_binaries.addOptionPath("pizza", transition_cli.getEmittedBin());
    test_binaries.addOptionPath("tools", tool.getEmittedBin());
    test_binaries.addOptionPath("runner", runner.getEmittedBin());
    test_binaries.addOptionPath("application", application.getEmittedBin());
    const integration_tests = b.addTest(
        .{
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("test/tests.zig"),
                    .target = host_target,
                    .optimize = .debug,
                    .imports = &.{
                        .{ .name = "utils", .module = utils },
                        .{ .name = "vm", .module = vm },
                        .{ .name = "bundle", .module = bundle },
                        .{ .name = "proto", .module = proto },
                    },
                },
            ),
        },
    );
    integration_tests.root_module.addImport("journal", journal);
    enableNewElfLinker(integration_tests);
    integration_tests.root_module.addOptions("test_binaries", test_binaries);
    const run_integration = b.addRunArtifact(integration_tests);
    run_integration.setCwd(b.path("."));
    run_integration.step.dependOn(b.getInstallStep());
    test_step.dependOn(&runner.step);
    test_step.dependOn(&application.step);
    test_step.dependOn(&run_integration.step);
    const frontend_tests = b.addSystemCommand(&.{ npm, "--prefix", "ui", "test" });
    test_step.dependOn(&frontend_tests.step);

    const generate = command(b, tool, &.{"proto"});
    b.step("proto", "Regenerate protocol bindings").dependOn(&generate.step);

    b.step(
        "check-proto",
        "Fail if generated contract files drift",
    ).dependOn(&check.step);

    const panel = b.addSystemCommand(
        &.{
            npm,
            "--prefix",
            "ui",
            "run",
            "build",
            "--",
            "--proto-checker",
        },
    );
    panel.addArtifactArg(tool);
    panel.step.dependOn(&check.step);
    run_bridge.step.dependOn(&panel.step);
    b.step("panel", "Build the initramfs execution GUI").dependOn(&panel.step);

    const bundle_step = bundle_steps.add(b, tool, maintenance, application, panel);

    const all = b.step("all", "Build core, frontend and the complete bundle");
    all.dependOn(bundle_step);
    all.dependOn(b.getInstallStep());
    all.dependOn(&panel.step);
    const frontend_check = b.addSystemCommand(
        &.{
            npm,
            "--prefix",
            "ui",
            "run",
            "check",
        },
    );
    const check_step = b.step(
        "check",
        "Check protocol drift and frontend syntax",
    );
    check_step.dependOn(&check.step);
    check_step.dependOn(&frontend_check.step);
    for ([_][3][]const u8{
        .{
            "doctor",
            "doctor",
            "Check host build dependencies",
        },
        .{
            "bootstrap-zig",
            "bootstrap-zig",
            "Fetch and verify the pinned toolchain outside the checkout",
        },
        .{
            "clean",
            "clean",
            "Remove only enumerated generated outputs",
        },
    }) |entry| {
        const run = command(b, tool, &.{entry[1]});
        run.addPassthruArgs();
        b.step(entry[0], entry[2]).dependOn(&run.step);
    }
    for ([_][3][]const u8{
        .{ "test-smoke", "smoke", "Boot the static PID 1 in QEMU" },
        .{ "test-maintenance", "maintenance", "Boot the layered maintenance image in QEMU" },
        .{
            "test-transition",
            "transition",
            "Check an explicitly supplied full-transition fixture",
        },
        .{ "test-matrix", "matrix", "Run isolated ABI checks with supplied cloud fixtures" },
    }) |entry| {
        const run = command(b, runner, &.{entry[1]});
        run.addPassthruArgs();
        if (std.mem.eql(u8, entry[0], "test-smoke"))
            run.step.dependOn(b.getInstallStep());
        b.step(entry[0], entry[2]).dependOn(&run.step);
    }
}

/// UI sources live under ui/; each target shares one business/protocol identity.
fn executionModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    proto: *std.Build.Module,
    utils: *std.Build.Module,
    journal: *std.Build.Module,
    session: *std.Build.Module,
) struct { maintenance: *std.Build.Module, gui: *std.Build.Module, tui: *std.Build.Module } {
    const tui = b.createModule(.{
        .root_source_file = b.path("ui/execution/tui/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "proto", .module = proto },
            .{ .name = "journal", .module = journal },
            .{ .name = "vaxis", .module = b.dependency("vaxis", .{ .target = target, .optimize = optimize }).module("vaxis") },
        },
    });
    const maintenance = b.createModule(.{
        .root_source_file = b.path("core/maint/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "proto", .module = proto },
            .{ .name = "utils", .module = utils },
            .{ .name = "journal", .module = journal },
            .{ .name = "execution_tui", .module = tui },
            .{ .name = "session", .module = session },
        },
    });
    const gui = b.createModule(.{
        .root_source_file = b.path("ui/execution/gui/host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "proto", .module = proto },
            .{ .name = "maintenance", .module = maintenance },
        },
    });
    return .{ .maintenance = maintenance, .gui = gui, .tui = tui };
}

fn enableNewElfLinker(compile: *std.Build.Step.Compile) void {
    if (compile.rootModuleTarget().os.tag != .linux) return;
    compile.use_lld = false;
    compile.use_new_linker = true;
}

fn command(
    b: *std.Build,
    tool: *std.Build.Step.Compile,
    args: []const []const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(tool);
    run.setCwd(b.path("."));
    run.addArgs(args);
    return run;
}

fn requireHostTool(
    b: *std.Build,
    variable: []const u8,
    default: []const u8,
) []const u8 {
    const name = b.graph.environ_map.get(variable) orelse default;
    return b.findProgram(.{ .names = &.{name} }) orelse
        std.process.fatal(
            "Required host tool '{s}' is unavailable; install it and add it to PATH (or set {s}).",
            .{ name, variable },
        );
}

fn sessionModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, proto: *std.Build.Module, utils: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("core/session.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "proto", .module = proto }, .{ .name = "utils", .module = utils } } });
}
