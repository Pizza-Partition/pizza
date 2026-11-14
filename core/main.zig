//! Composition root: CLI dispatch and concrete platform wiring.
const json = @import("json.zig").json;
const std = @import("std");
const cli = @import("cli.zig");
const wire = @import("proto").wire;
const application = @import("app/service.zig");
const builtin = @import("builtin");
const Disk = switch (builtin.os.tag) {
    .linux => @import("platform/linux/disk.zig"),
    .windows => @import("platform/windows/disk.zig"),
    else => @compileError("Pizza only supports Linux and Windows"),
};
const Sessions = switch (builtin.os.tag) {
    .linux => @import("platform/linux/privileged_service.zig"),
    .windows => @import("platform/windows/privileged_service.zig"),
    else => unreachable,
};
const Maintenance = switch (builtin.os.tag) {
    .linux => @import("platform/linux/maintenance.zig").Maintenance,
    .windows => @import("platform/windows/maintenance.zig").Maintenance,
    else => unreachable,
};

const Service = application.service(Disk, Sessions);

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const options = try cli.parse(a, args[1..]);
    if (options.help) {
        try cli.help(init.io, options.mode);
        return 0;
    }

    var maintenance: Maintenance = .{ .image_digest = @import("build_options").maintenance_image_digest, .io = init.io };
    var app: Service = .{ .io = init.io, .disk = .{ .io = init.io }, .maintenance = maintenance.controller() };
    if (comptime builtin.os.tag == .windows) app.sessions.parent_pid = options.parent_pid;
    switch (options.mode) {
        // Privileged services, use for disk operations and session management. This mode is only
        // available to the privileged CLI.
        .@"privileged-exec" => return app.serve(),
        // Returns a JSON-encoded inventory of the host's disks and partitions in standard output.
        .inventory => {
            try std.Io.File.stdout().writeStreamingAll(
                init.io,
                try json(a, try app.disk.query(a)),
            );
            return 0;
        },
        // Reads a JSON-encoded plan draft from standard input, validates it against the current
        // disk state, and returns a JSON-encoded validated plan in standard output.
        .plan => {
            var reader = std.Io.File.stdin().readerStreaming(init.io, &.{});
            const bytes = try reader.interface.allocRemaining(a, .limited(application.MAX_BYTES));
            try std.Io.File.stdout().writeStreamingAll(init.io, try app.plan(a, bytes));
            return 0;
        },
        .validate => {
            var reader = std.Io.File.stdin().readerStreaming(init.io, &.{});
            const bytes = try reader.interface.allocRemaining(a, .limited(application.MAX_BYTES));
            const draft = try std.json.parseFromSliceLeaky(wire.PlanDraft, a, bytes, .{});
            try std.Io.File.stdout().writeStreamingAll(
                init.io,
                try json(a, try @import("planning/planner.zig").validate(a, try app.disk.query(a), draft, &app.disk)),
            );
            return 0;
        },
        .request => {
            var reader = std.Io.File.stdin().readerStreaming(init.io, &.{});
            const bytes = try reader.interface.allocRemaining(a, .limited(application.MAX_BYTES));
            // A direct privileged CLI request owns this worker. Keep its
            // service context alive until the task releases the write lease.
            if (comptime builtin.os.tag == .windows) {
                if (app.sessions.isPrivileged()) try app.sessions.openRecords(a);
            }
            defer if (comptime builtin.os.tag == .windows) app.sessions.closeRecords();
            defer app.sessions.worker.wait(init.io);
            const response = try app.dispatch(a, bytes, if (app.sessions.isPrivileged()) .privileged else .local);
            try std.Io.File.stdout().writeStreamingAll(init.io, response);
            return 0;
        },
        .@"complete-session" => {
            const request = try json(a, wire.PrivilegedRequest{ .version = @import("proto").API_VERSION, .action = .complete });
            try std.Io.File.stdout().writeStreamingAll(init.io, try app.dispatch(a, request, if (app.sessions.isPrivileged()) .privileged else .local));
            return 0;
        },
        .ui, .serve => {},
    }
    if (comptime @import("build_options").headless) return error.GuiUnavailable;
    if (app.sessions.isPrivileged()) return error.UiMustRunUnprivileged;
    return @import("desktop/window.zig").run(a, init.io, .{ .mode = if (options.mode == .serve) .browser else .desktop, .port = options.port }, &app);
}
