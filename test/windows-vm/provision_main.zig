const std = @import("std");
pub fn main(init: std.process.Init) !void {
    return @import("vm_runtime").provision(init);
}
