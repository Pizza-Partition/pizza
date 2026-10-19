const std = @import("std");

/// Reads a nonnegative integer or parses a decimal string/number_string as u64.
/// Rejects other value kinds and propagates integer parsing errors.
pub fn unsigned(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else error.ExpectedUnsigned,
        .number_string, .string => |s| std.fmt.parseInt(u64, s, 10),
        else => error.ExpectedUnsigned,
    };
}

/// Compares JSON values recursively, requiring matching value kinds.
/// Array order matters; object key order does not.
pub fn equal(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b))
        return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .string, .number_string => |v| std.mem.eql(
            u8,
            v,
            switch (b) {
                .string => b.string,
                .number_string => b.number_string,
                else => unreachable,
            },
        ),
        .array => |v| blk: {
            if (v.items.len != b.array.items.len)
                break :blk false;
            for (v.items, b.array.items) |x, y| if (!equal(x, y))
                break :blk false;
            break :blk true;
        },
        .object => |v| blk: {
            if (v.count() != b.object.count())
                break :blk false;
            var entries = v.iterator();
            while (entries.next()) |entry| if (!equal(
                entry.value_ptr.*,
                b.object.get(entry.key_ptr.*) orelse break :blk false,
            ))
                break :blk false;
            break :blk true;
        },
    };
}
