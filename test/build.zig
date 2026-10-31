//! Stage a common module root without putting test-only roots in core/.
const std = @import("std");
pub const Sources = struct {
    b: *std.Build,
    files: *std.Build.Step.WriteFile,
    pub fn init(b: *std.Build) Sources {
        const files = b.addWriteFiles();
        _ = files.addCopyDirectory(b.path("core"), "core", .{ .include_extensions = &.{".zig"} });
        _ = files.addCopyDirectory(b.path("test"), "test", .{ .include_extensions = &.{ ".zig", ".json" } });
        return .{ .b = b, .files = files };
    }
    pub fn root(s: Sources, entry: []const u8) std.Build.LazyPath {
        return s.files.add(s.b.fmt("{s}-root.zig", .{entry}), s.b.fmt("comptime {{ _ = @import(\"test/{s}\"); }}\n", .{entry}));
    }
};
