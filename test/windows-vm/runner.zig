const std = @import("std");
const vm = @import("vm_runtime");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var parsed = try vm.cli.Runner.parse(init.arena.allocator(), args[1..]);
    defer parsed.deinit();
    if (parsed.args.help != 0) return vm.cli.help(init.io, vm.cli.Runner);
    std.testing.allocator_instance = .init(std.heap.page_allocator, .{});
    defer if (std.testing.allocator_instance.deinit() != 0) @panic("Test allocator leaked");
    std.testing.io_instance = .init(std.testing.allocator, .{ .environ = init.minimal.environ });
    defer std.testing.io_instance.deinit();
    std.testing.environ = init.minimal.environ;
    var machine = try vm.Vm.init(init, parsed.args);
    defer machine.deinit();
    vm.context = &machine;
    machine.startSuite() catch |err| {
        machine.failure(err);
        return err;
    };
    var count: usize = 0;
    for (@import("builtin").test_functions) |t| {
        std.debug.print("{s}...\n", .{t.name});
        t.func() catch |err| {
            if (err == error.SkipZigTest) continue;
            machine.failure(err);
            return err;
        };
        count += 1;
        std.debug.print("OK\n", .{});
    }
    machine.finish() catch |err| {
        machine.failure(err);
        return err;
    };
    std.debug.print("Windows VM scenarios passed: {d}; Zig test functions passed: {d}.\n", .{ machine.results.items.len, count });
}
