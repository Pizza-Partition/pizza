const std = @import("std");
pub const wire = @import("generated.zig");

pub const api_version = wire.api_version;
pub const bridge_channel = wire.bridge_channel;
pub const Context = wire.Context;
pub const Plan = wire.Plan;
pub const Event = wire.Event;
pub const JournalPhase = wire.JournalPhase;

test "journal header size is stable" {
    try std.testing.expectEqual(@as(usize, 64), wire.journal_header_bytes);
    try std.testing.expectEqual(@as(u32, 0x505a4a31), wire.journal_magic);
}

pub fn validatePlan(plan: Plan) !void {
    if (plan.version != api_version or plan.id.len == 0 or plan.id.len > 64 or plan.steps.len != 20) return error.InvalidPlan;
    for (plan.id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidPlan;
    for (plan.steps, 0..) |step, index| {
        if (!step.simulated or step.id == 0 or step.label.len == 0 or step.label.len > 256 or !std.unicode.utf8ValidateSlice(step.label)) return error.InvalidPlan;
        for (plan.steps[0..index]) |previous| if (step.id == previous.id) return error.InvalidPlan;
    }
}
