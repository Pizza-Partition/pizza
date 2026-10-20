//! Publisher authentication policy, verified offline with native Zig cryptography.
const std = @import("std");
const utils = @import("utils");
const files = @import("files.zig");
pub const repository = "Pizza-Partition/pizza-bundle";
pub const repository_id = "1425566562";
pub const workflow = repository ++ "/.github/workflows/release.yml";
pub const lock_path = "config/bundle/release.json";

pub const Lock = struct {
    repository: []const u8,
    repository_id: []const u8,
    workflow: []const u8,
    tag: []const u8,
    commit: []const u8,
    asset: []const u8,
    sha256: []const u8,
    kernel_asset: []const u8,
    kernel_sha256: []const u8,
    metadata_asset: []const u8,
    metadata_sha256: []const u8,

    pub fn validate(self: Lock) !void {
        if (!std.mem.eql(u8, self.repository, repository) or !std.mem.eql(u8, self.repository_id, repository_id) or !std.mem.eql(u8, self.workflow, workflow) or
            !std.mem.eql(u8, self.asset, "pizza-base-x86_64.img") or !std.mem.eql(u8, self.kernel_asset, "vmlinuz") or !std.mem.eql(u8, self.metadata_asset, "base.json") or
            !hex(self.commit, 40) or !hex(self.sha256, 64) or !hex(self.kernel_sha256, 64) or !hex(self.metadata_sha256, 64)) return error.InvalidReleaseLock;
        if (self.tag.len < 2 or self.tag[0] != 'v') return error.InvalidReleaseLock;
        for (self.tag[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "_.+-", byte) == null) return error.InvalidReleaseLock;
    }
};

fn hex(value: []const u8, size: usize) bool {
    if (value.len != size) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

pub fn readLock(a: std.mem.Allocator, io: std.Io, path: []const u8) !Lock {
    const lock = try files.readJson(Lock, a, io, path);
    try lock.validate();
    return lock;
}

pub fn verifyDigest(a: std.mem.Allocator, io: std.Io, path: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, try utils.filesystem.hashFileSha256(a, io, path), expected)) {
        return error.ReleaseDigestMismatch;
    }
}

pub const Base = struct {
    format: u16,
    kind: []const u8,
    architecture: []const u8,
    profile: []const u8,
    kernel_version: []const u8,
    kernel_release: []const u8,
    initramfs: []const u8,
    kernel: []const u8,
    application_overlay: struct { init: []const u8, runtime_root: []const u8, panel: []const u8 },

    pub fn validate(self: Base) !void {
        if (self.format != 1) return error.IncompatibleBaseImage;
        const pairs = [_][2][]const u8{ .{ self.kind, "pizza-base" }, .{ self.architecture, "x86_64" }, .{ self.profile, "wpe-platform-v2" }, .{ self.kernel_version, "7.2.11" }, .{ self.kernel_release, "7.2.11-arch1-1" }, .{ self.initramfs, "pizza-base-x86_64.img" }, .{ self.kernel, "vmlinuz" }, .{ self.application_overlay.init, "/init" }, .{ self.application_overlay.runtime_root, "/opt/pizza/bundle" }, .{ self.application_overlay.panel, "/opt/pizza/panel" } };
        for (pairs) |pair| if (!std.mem.eql(u8, pair[0], pair[1])) return error.IncompatibleBaseImage;
    }
};

pub fn verify(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, root: []const u8, lock: Lock) !Base {
    try lock.validate();
    _ = env;
    try verifyDigest(a, io, try files.join(a, &.{ root, lock.asset }), lock.sha256);
    try verifyDigest(a, io, try files.join(a, &.{ root, lock.kernel_asset }), lock.kernel_sha256);
    try verifyDigest(a, io, try files.join(a, &.{ root, lock.metadata_asset }), lock.metadata_sha256);
    const now = std.Io.Clock.real.now(io).toSeconds();
    if (now < 0) return error.InvalidClock;
    try @import("sigstore.zig").verify(a, try std.Io.Dir.cwd().readFileAlloc(io, try files.join(a, &.{ root, "attestation.json" }), a, .limited(1024 * 1024)), .{
        .repository = lock.repository,
        .repository_id = lock.repository_id,
        .workflow = lock.workflow,
        .tag = lock.tag,
        .commit = lock.commit,
    }, &.{ .{ lock.asset, lock.sha256 }, .{ lock.kernel_asset, lock.kernel_sha256 }, .{ lock.metadata_asset, lock.metadata_sha256 } }, @intCast(now));
    const base = try files.readJson(Base, a, io, try files.join(a, &.{ root, lock.metadata_asset }));
    try base.validate();
    return base;
}

pub fn fetch(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, lock_file: []const u8, destination: []const u8) !void {
    const lock = try readLock(a, io, lock_file);
    const output = try files.Output.init(a, io, destination, true);
    defer output.deinit(io);
    for ([_][]const u8{ lock.asset, lock.kernel_asset, lock.metadata_asset, "attestation.json" }) |name| {
        try utils.process.runInherited(io, env, &.{ "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3", "--output", try files.join(a, &.{ output.temporary, name }), try a.print("https://github.com/{s}/releases/download/{s}/{s}", .{ repository, lock.tag, name }) });
    }
    _ = try verify(a, io, env, output.temporary, lock);
    try output.publish(io, output.temporary);
}
