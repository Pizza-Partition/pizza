//! Refresh disk evidence before checking an approval.
const std = @import("std");
const wire = @import("proto").wire;
pub fn check(app: anytype, a: std.mem.Allocator, r: wire.PrivilegedRequest) !struct { snapshot: wire.InventorySnapshot, validated: wire.ValidatedPlan } {
    const draft = r.draft orelse return error.MissingDraft;
    const snapshot = try app.disk.query(a);
    const validated = try @import("../planning/planner.zig").validate(a, snapshot, draft, &app.disk);
    if (!std.mem.eql(u8, validated.digest, r.approved_digest orelse return error.MissingApproval)) return error.PlanApprovalChanged;
    return .{ .snapshot = snapshot, .validated = validated };
}
