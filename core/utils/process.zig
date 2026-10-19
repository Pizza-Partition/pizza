const std = @import("std");

/// Finds a regular executable using the supplied PATH, or checks an explicit path.
/// An explicit path is returned borrowed; a PATH lookup returns an allocator-owned path.
/// Returns MissingTool when no executable is found.
pub fn findExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    name: []const u8,
) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        std.Io.Dir.cwd().access(io, name, .{ .execute = true }) catch {
            return error.MissingTool;
        };
        const stat = std.Io.Dir.cwd().statFile(io, name, .{}) catch return error.MissingTool;
        if (stat.kind != .file)
            return error.MissingTool;
        return name;
    }
    var paths = std.mem.splitScalar(
        u8,
        (environ.get("PATH") orelse ""),
        ':',
    );
    while (paths.next()) |parent| {
        const candidate = try std.fs.path.join(allocator, &.{ parent, name });
        std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
        if (stat.kind == .file)
            return candidate;
    }
    std.log.err("Missing system tool: {s}", .{name});
    return error.MissingTool;
}

/// Returns allocator-backed stdout only when the captured command exits with status zero.
/// On another termination status, logs stderr and returns CommandFailed.
pub fn checkedOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    argv: []const []const u8,
) ![]const u8 {
    const output = try std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = environ,
        .stdout_limit = .limited(32 * 1024 * 1024),
        .stderr_limit = .limited(32 * 1024 * 1024),
    });
    if (output.term != .exited or output.term.exited != 0) {
        std.log.err(
            "Command failed: {s}\n{s}",
            .{ argv[0], output.stderr },
        );
        return error.CommandFailed;
    }
    return output.stdout;
}

/// Runs a command with inherited standard streams and the supplied environment.
/// Waits for completion and returns CommandFailed unless the command exits with status zero.
pub fn runInherited(io: std.Io, environ: *std.process.Environ.Map, argv: []const []const u8) !void {
    var child = try std.process.spawn(
        io,
        .{ .argv = argv, .environ_map = environ },
    );
    defer child.kill(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0)
        return error.CommandFailed;
}
