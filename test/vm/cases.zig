//! One scenario definition and console decision flow for Linux and Windows.
const std = @import("std");
pub const Case = enum { accept, undo, @"powercut-undo", @"powercut-accept", @"powercut-apply" };
pub const csv = "accept,undo,powercut-undo,powercut-accept,powercut-apply";
pub fn validate(selection: []const u8) !void {
    var seen: std.EnumSet(Case) = .{};
    var it = std.mem.splitScalar(u8, selection, ',');
    while (it.next()) |name| {
        const case = std.meta.stringToEnum(Case, name) orelse return error.InvalidCase;
        if (seen.contains(case)) return error.DuplicateCase;
        seen.insert(case);
    }
}
pub fn accepts(case: []const u8) bool {
    return std.mem.eql(u8, case, "accept") or std.mem.eql(u8, case, "powercut-accept");
}

test "both runners reject unknown, empty and repeated scenario selections" {
    try validate(csv);
    try validate("accept,undo");
    for ([_][]const u8{ "", "unknown", "accept,", ",undo" }) |invalid| try std.testing.expectError(error.InvalidCase, validate(invalid));
    try std.testing.expectError(error.DuplicateCase, validate("accept,accept"));
    try std.testing.expect(accepts("powercut-accept"));
    try std.testing.expect(!accepts("powercut-undo"));
}

/// The VM port owns transport, clocks and actual power loss. Return a cursor
/// for the platform-specific wait until its primary OS is ready again.
pub fn run(vm: anytype, case: []const u8) !usize {
    if (std.meta.stringToEnum(Case, case) == null) return error.InvalidCase;
    try vm.guest("plan", case);
    try vm.guest("prepare", case);
    const start = vm.consoleMark();
    try vm.guest("reboot", case);
    if (std.mem.eql(u8, case, "powercut-apply")) {
        try vm.wait("PIZZA_RESTART_APPLY", start);
        try vm.powercut();
        const recovery = vm.consoleMark();
        try vm.boot();
        const until = vm.endTime();
        var continued = false;
        var decided = false;
        while (vm.now() < until) {
            try vm.pump();
            if (vm.contains(recovery, "PIZZA_RESTART_RETURN_READY")) break;
            if (!continued and vm.contains(recovery, "Recovered session. Press C")) {
                try vm.send("c\n");
                continued = true;
            }
            if (!decided and vm.contains(recovery, "Press A then Enter")) {
                try vm.send("u\n");
                decided = true;
            }
        }
        try vm.wait("PIZZA_RESTART_RETURN_READY", recovery);
    } else {
        try vm.wait("Press A then Enter to accept", start);
        if (std.mem.startsWith(u8, case, "powercut-")) {
            try vm.powercut();
            const recovery = vm.consoleMark();
            try vm.boot();
            try vm.wait("Press A then Enter to accept", recovery);
        }
        try vm.send(if (accepts(case)) "a\n" else "u\n");
        try vm.wait("PIZZA_RESTART_RETURN_READY", start);
    }
    return start;
}
