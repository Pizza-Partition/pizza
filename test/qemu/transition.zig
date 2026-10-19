const std = @import("std");
const utils = @import("utils");
const clap = @import("clap");
const h = @import("harness.zig");

const required = [_][]const u8{
    "kexec_without_firmware",
    "ram_root",
    "original_root_readonly",
    "original_hash_unchanged",
    "health_ok",
    "context_maint",
    "untrusted_document_rejected",
    "bridge_version_rejected",
    "bridge_replay_correct",
    "journal_crc_valid",
    "completion_boundary",
    "post_reboot_report",
};
fn assertResult(result: std.json.Value) !void {
    for (required) |key| {
        const value = (switch (result) {
            .object => |object| object.get(key) orelse return error.MissingField,
            else => return error.ExpectedObject,
        });
        if (value != .bool or !value.bool)
            return error.AcceptanceAssertionFailed;
    }
    if (try utils.json.unsigned((switch (result) {
        .object => |object| object.get("step_events") orelse return error.MissingField,
        else => return error.ExpectedObject,
    })) != 20)
        return error.ExpectedTwentyCommits;
    const sequences = (switch (result) {
        .object => |object| object.get("event_sequences") orelse return error.MissingField,
        else => return error.ExpectedObject,
    });
    if (sequences != .array or sequences.array.items.len != 20) {
        return error.MissingSequenceEvidence;
    }
    var previous: u64 = 0;
    for (sequences.array.items) |sequence| {
        const value = try utils.json.unsigned(sequence);
        if (value <= previous)
            return error.NonMonotonicSequence;
        previous = value;
    }
    const peak = (switch (result) {
        .object => |object| object.get("peak_rss_kib") orelse return error.MissingField,
        else => return error.ExpectedObject,
    });
    const budget = (switch (result) {
        .object => |object| object.get("memory_budget_kib") orelse return error.MissingField,
        else => return error.ExpectedObject,
    });
    if (peak != .integer or budget != .integer or
        peak.integer <= 0 or peak.integer > budget.integer)
    {
        return error.MissingOrExceededMemoryBudget;
    }
}

const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--kernel <str>  Instrumented guest kernel (required).
    \\--initrd <str>  Instrumented guest initramfs (required).
    \\--root-disk <str>  Read-only qcow2 root fixture (required).
    \\--journal-disk <str>  Snapshot-backed qcow2 journal fixture (required).
    \\--timeout <u32>  VM timeout in seconds (default: 180).
);

/// Runs explicit guest fixtures and checks a single acceptance report against the transition gate.
/// Parses subcommand arguments and independently compares root-disk hashes before and after the VM.
/// Other acceptance facts come from guest evidence; missing fixtures or failed assertions return errors.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    argv: []const []const u8,
) !void {
    var iter: clap.args.SliceIterator = .{ .args = argv };
    var diagnostic: clap.Diagnostic = .{};
    var parsed = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
        .diagnostic = &diagnostic,
    }) catch |err| {
        std.log.err("Command line: {t}; argument: {s}", .{ err, diagnostic.arg });
        return err;
    };
    defer parsed.deinit();
    if (parsed.args.help != 0) {
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: pizza-tests transition [options]\n");
        return clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    }
    if (parsed.args.kernel == null or parsed.args.initrd == null or
        parsed.args.@"root-disk" == null or parsed.args.@"journal-disk" == null)
    {
        std.log.err(
            "Phase 7 fixture is not implemented. Supply --kernel, --initrd,\n" ++
                "--root-disk and --journal-disk; a smoke boot is not a transition.",
            .{},
        );
        return error.TransitionFixtureRequired;
    }
    const kernel = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        (parsed.args.kernel orelse return error.MissingKernel),
        allocator,
    );
    const initrd = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        (parsed.args.initrd orelse return error.MissingInitrd),
        allocator,
    );
    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        (parsed.args.@"root-disk" orelse return error.MissingRootDisk),
        allocator,
    );
    const journal = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        (parsed.args.@"journal-disk" orelse return error.MissingJournalDisk),
        allocator,
    );
    try h.noComma(root);
    try h.noComma(journal);
    const output = try utils.filesystem.createTemporaryDirectory(
        allocator,
        io,
        "pizza-qemu-transition-",
    );
    const before = try utils.filesystem.hashFileSha256(allocator, io, root);
    var command = try h.baseCommand(allocator, io, environ, output, 1024);
    try command.appendSlice(
        &.{
            "-nic",
            "none",
            "-kernel",
            kernel,
            "-initrd",
            initrd,
            "-append",
            "console=ttyS0 rdinit=/init pizza.test=acceptance",
            "-drive",
            try allocator.print(
                "if=virtio,format=qcow2,readonly=on,file={s}",
                .{root},
            ),
            "-drive",
            try allocator.print(
                "if=virtio,format=qcow2,snapshot=on,file={s}",
                .{journal},
            ),
        },
    );
    const serial = try h.runVm(
        allocator,
        io,
        environ,
        command.items,
        output,
        parsed.args.timeout orelse 180,
    );
    var lines = std.mem.splitScalar(u8, serial, '\n');
    var evidence: ?[]const u8 = null;
    while (lines.next()) |line| if (std.mem.indexOf(u8, line, "PIZZA_ACCEPTANCE_JSON:")) |index| {
        if (evidence != null)
            return error.DuplicateAcceptanceEvidence;
        evidence = line[index + "PIZZA_ACCEPTANCE_JSON:".len ..];
    };
    var result = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        evidence orelse return error.MissingAcceptanceEvidence,
        .{ .allocate = .alloc_always },
    );
    const after = try utils.filesystem.hashFileSha256(allocator, io, root);
    try result.object.put(
        allocator,
        "original_hash_unchanged",
        .{ .bool = std.mem.eql(u8, before, after) },
    );
    try result.object.put(
        allocator,
        "original_hash_before",
        std.json.Value{ .string = before },
    );
    try result.object.put(
        allocator,
        "original_hash_after",
        std.json.Value{ .string = after },
    );
    try assertResult(result);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(
            allocator,
            &.{ output, "results.json" },
        ),
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            result,
            .{ .whitespace = .indent_2 },
        ),
    });
    std.log.info("Transition artifacts: {s}", .{output});
}

test "transition gate rejects smoke evidence, duplicate sequences and zero RSS" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(
        error.MissingField,
        assertResult(
            try std.json.parseFromSliceLeaky(
                std.json.Value,
                allocator,
                "{\"marker\":true}",
                .{ .allocate = .alloc_always },
            ),
        ),
    );
    var result = std.json.Value{ .object = .{} };
    for (required) |key| try result.object.put(
        allocator,
        key,
        .{ .bool = true },
    );
    var sequences = std.json.Value{
        .array = std.json.Array.init(allocator),
    };
    for (1..21) |number| try sequences.array.append(.{ .integer = @intCast(number) });
    try result.object.put(
        allocator,
        "step_events",
        .{ .integer = 20 },
    );
    try result.object.put(
        allocator,
        "event_sequences",
        sequences,
    );
    try result.object.put(
        allocator,
        "peak_rss_kib",
        .{ .integer = 512 },
    );
    try result.object.put(
        allocator,
        "memory_budget_kib",
        .{ .integer = 1024 },
    );
    try assertResult(result);
    result.object.getPtr("event_sequences").?.array.items[2] = .{ .integer = 2 };
    try std.testing.expectError(
        error.NonMonotonicSequence,
        assertResult(result),
    );
    result.object.getPtr("event_sequences").?.array.items[2] = .{ .integer = 3 };
    try result.object.put(
        allocator,
        "peak_rss_kib",
        .{ .integer = 0 },
    );
    try std.testing.expectError(
        error.MissingOrExceededMemoryBudget,
        assertResult(result),
    );
}
