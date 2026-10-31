//! Compile this root without system or WebUI imports to verify the business boundary.
const std = @import("std");
test {
    _ = @import("../core/cli.zig");
    _ = @import("../core/planning/planner.zig");
    _ = @import("../core/planning/editor.zig");
    _ = @import("../core/execution/state.zig");
    _ = @import("../core/execution/runner.zig");
    _ = @import("../core/boot/uefi.zig");
    _ = @import("../core/boot/session.zig");
    _ = @import("domain/planner.zig");
    _ = @import("domain/worker.zig");
    _ = @import("domain/application.zig");
    _ = @import("../core/platform/windows/policy.zig");
    _ = @import("../core/planning/identity.zig");
}
test "protocol rejects old plan versions" {
    try std.testing.expectError(error.InvalidPlan, @import("proto").validatePlan(.{ .id = "old", .version = @import("proto").API_VERSION - 1 }));
}
