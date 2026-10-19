//! Read-only post-reboot timeline and conservative step reconciliation.
const std = @import("std");
const journal = @import("journal");

const Event = struct {
    seq: []const u8,
    monotonic_ns: []const u8,
    step_id: u32,
    phase: journal.Phase,
    payload_text: ?[]const u8,
    payload_hex: []const u8,
    boundary: ?journal.Boundary,
};
const Step = struct { id: u32, state: journal.StepState, seq: []const u8 };

/// Returns JSON owned by the caller's arena. Partial tails are visible in the
/// result, together with the exact valid byte prefix; no repair is attempted.
pub fn render(allocator: std.mem.Allocator, parsed: journal.Scan) ![]const u8 {
    const events = try allocator.alloc(Event, parsed.records.len);
    for (parsed.records, events) |record, *event| {
        const hex = try allocator.alloc(u8, record.payload.len * 2);
        const digits = "0123456789abcdef";
        for (record.payload, 0..) |byte, index| {
            hex[index * 2] = digits[byte >> 4];
            hex[index * 2 + 1] = digits[byte & 15];
        }
        event.* = .{
            .seq = try allocator.print("{d}", .{record.seq}),
            .monotonic_ns = try allocator.print("{d}", .{record.monotonic_ns}),
            .step_id = record.step_id,
            .phase = record.phase,
            .payload_text = if (std.unicode.utf8ValidateSlice(record.payload)) record.payload else null,
            .payload_hex = hex,
            .boundary = if (record.phase == .boundary) try std.json.parseFromSliceLeaky(journal.Boundary, allocator, record.payload, .{}) else null,
        };
    }
    const steps = try allocator.alloc(Step, parsed.state.steps.count());
    for (parsed.state.steps.keys(), parsed.state.steps.values(), steps) |id, step, *output|
        output.* = .{ .id = id, .state = step.state, .seq = try allocator.print("{d}", .{step.seq}) };
    std.mem.sort(Step, steps, {}, struct {
        fn less(_: void, left: Step, right: Step) bool {
            return left.id < right.id;
        }
    }.less);
    return std.json.Stringify.valueAlloc(allocator, .{
        .format_version = journal.format_version,
        .tail = parsed.tail,
        .valid_bytes = parsed.valid_bytes,
        .last_seq = try allocator.print("{d}", .{parsed.state.seq}),
        .completed = parsed.state.complete,
        .steps = steps,
        .timeline = events,
    }, .{ .whitespace = .indent_2 });
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{});
    defer directory.close(io);
    const session = @import("session");
    const marker = session.readMarker(allocator, io, directory) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const parsed = journal.readFile(allocator, io, path) catch |err| {
        if (err != error.FileNotFound or marker == null) return err;
        const m = marker.?;
        const same_boot = std.mem.eql(u8, try session.bootId(allocator, io), m.request.source_boot_id);
        const status: session.Status = if (m.status == .staged) .staged else if (m.status == .loaded and same_boot) .loaded else .interrupted;
        try std.Io.File.stdout().writeStreamingAll(io, try std.json.Stringify.valueAlloc(allocator, .{
            .format_version = journal.format_version,
            .completed = false,
            .last_seq = "0",
            .transition = .{ .recorded = m, .reconciled_status = status, .journal_missing = true },
        }, .{ .whitespace = .indent_2 }));
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        return;
    };
    var value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, try render(allocator, parsed), .{});
    if (marker) |m| {
        if (parsed.records.len == 0) return error.MissingBoundary;
        const boundary = try std.json.parseFromSliceLeaky(journal.Boundary, allocator, parsed.records[0].payload, .{});
        if (!std.mem.eql(u8, boundary.plan_id, m.request.plan_id) or
            !std.mem.eql(u8, boundary.home.device_uuid orelse return error.JournalIdentityMissing, m.request.home.uuid) or
            !std.mem.eql(u8, boundary.home.device_path orelse return error.JournalIdentityMissing, m.request.home.path)) return error.JournalTransitionMismatch;
        const status: session.Status = if (parsed.state.complete) .completed else .interrupted;
        const detail = try std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, .{ .recorded = m, .reconciled_status = status }, .{}), .{});
        try value.object.put(allocator, "transition", detail);
    }
    try std.Io.File.stdout().writeStreamingAll(io, try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 }));
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}
