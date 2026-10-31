//! Build the host against its pinned maintenance release and record the VM artifacts.
const std = @import("std");
const u = @import("vm_common");
const digest = @import("fetch_image.zig").digest;
const defaults = @import("artifact_options");
const cli = @import("cli.zig");
const CMDLINE = "console=ttyS0,115200n8 console=tty0 rdinit=/init pizza.kiosk=disable";
const Builder = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    timeout: i64,

    fn command(b: Builder, cwd: []const u8, argv: []const []const u8) ![]const u8 {
        std.debug.print("build: {s}\n", .{argv[0]});
        return u.check(try u.runAt(b.a, b.io, b.env, .{ .path = cwd }, argv, null, b.timeout));
    }
    fn revision(b: Builder, root: []const u8) !struct { root: []const u8, commit: []const u8, status: []const u8 } {
        return .{
            .root = root,
            .commit = try b.command(root, &.{ "git", "rev-parse", "HEAD" }),
            .status = try b.command(root, &.{ "git", "status", "--short" }),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var parsed = try cli.Artifacts.parse(a, args[1..]);
    defer parsed.deinit();
    const options = parsed.args;
    if (options.help != 0) return cli.help(io, cli.Artifacts);
    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.resolve(a, &.{ cwd, options.root orelse defaults.root });
    const out = try std.fs.path.resolve(a, &.{ cwd, options.out orelse ".zig-cache/windows-e2e" });
    const stage = try std.fs.path.join(a, &.{ out, "stage" });
    const payload = try std.fs.path.join(a, &.{ stage, "share/pizza/maintenance" });
    const zig = options.zig orelse defaults.zig;
    const timeout = options.timeout orelse 3600;
    var env = try init.environ_map.clone(a);
    _ = env.swapRemove("PIZZA_VM_PASSWORD");
    const b: Builder = .{ .a = a, .io = io, .env = &env, .timeout = timeout };
    try std.Io.Dir.cwd().createDirPath(io, out);
    const manifest = try std.fs.path.join(a, &.{ out, "build.json" });
    std.Io.Dir.cwd().deleteFile(io, manifest) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.debug.print("Building Windows VM artifacts with the pinned maintenance release in {s}\n", .{out});
    _ = try b.command(root, &.{ zig, "build", "stage-windows-tests", "maintenance-files", "-Dheadless=true", "-Dtarget=x86_64-windows-gnu", "-Dwindows-lld=true", "-Doptimize=safe", "--prefix", stage });
    const initrd = try std.fs.path.join(a, &.{ payload, "maint.img" });
    const metadata = try std.json.parseFromSliceLeaky(struct { version: u32, kernel_version: []const u8, image_sha256: []const u8 }, a, try std.Io.Dir.cwd().readFileAlloc(io, try a.print("{s}.pizza.json", .{initrd}), a, .limited(512 * 1024 * 1024)), .{ .ignore_unknown_fields = true });
    const actual_initrd = try digest(io, initrd);
    if (metadata.version != 1 or metadata.kernel_version.len == 0 or !std.mem.eql(u8, &actual_initrd.sha256, metadata.image_sha256)) return error.MaintenanceMetadataMismatch;
    const image = try std.fs.path.join(a, &.{ payload, "maint.efi" });
    const image_hash = try digest(io, image);
    const Artifact = struct { path: []const u8, size: u64, sha256: [64]u8 };
    var artifacts: std.ArrayList(Artifact) = .empty;
    for ([_][]const u8{ "pizza-backend.exe", "windows-vm-guest.exe", "maint.efi", "windows-tests/domain-tests.exe", "windows-tests/protocol-tests.exe", "windows-tests/host-tests.exe", "windows-tests/image-tests.exe" }) |name| {
        const actual = try digest(io, try std.fs.path.join(a, &.{ stage, "bin", name }));
        if (actual.size == 0) return error.EmptyStagedArtifact;
        if (std.mem.eql(u8, name, "maint.efi") and !std.mem.eql(u8, &actual.sha256, &image_hash.sha256)) return error.StagedImageChanged;
        try artifacts.append(a, .{ .path = name, .size = actual.size, .sha256 = actual.sha256 });
    }
    const protocol_hash = try digest(io, try std.fs.path.join(a, &.{ payload, "protocol/manifest.json" }));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = try std.json.Stringify.valueAlloc(a, .{
        .version = @as(u32, 1),
        .host = try b.revision(root),
        .maintenance = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ payload, "release.json" }), a, .limited(65536)), .{}),
        .image_sha256 = image_hash.sha256,
        .trusted_image = image,
        .protocol_manifest_sha256 = protocol_hash.sha256,
        .cmdline = CMDLINE,
        .artifacts = artifacts.items,
    }, .{ .whitespace = .indent_2 }) });
    std.debug.print("Artifacts ready: {s}/bin; manifest: {s}\n", .{ stage, manifest });
}
