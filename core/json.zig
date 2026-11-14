//! Wire JSON omits absent optional fields.
const std = @import("std");
pub fn json(a: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, value, .{ .emit_null_optional_fields = false });
}
