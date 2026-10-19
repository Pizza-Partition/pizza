//! Matching, prebuilt maintenance image plus a protected session overlay.
const std = @import("std");
const session = @import("session");
const fs = @import("utils").filesystem;
const archive = @import("initramfs_archive");
pub const Metadata = struct { version: u16, development: bool = false, kernel_version: []const u8, image_sha256: []const u8 };

pub fn validate(a: std.mem.Allocator, io: std.Io, kernel: []const u8, initrd: []const u8) !Metadata {
    const metadata = try std.json.parseFromSliceLeaky(Metadata, a, try std.Io.Dir.cwd().readFileAlloc(io, try a.print("{s}.pizza.json", .{initrd}), a, .limited(4096)), .{});
    if (metadata.development) return error.DevelopmentImageCannotTransition;
    if (metadata.version != 1 or !session.hex(metadata.image_sha256, 64) or !std.mem.eql(u8, metadata.image_sha256, try fs.hashFileSha256(a, io, initrd))) return error.MaintenanceImageHashMismatch;
    const image = try std.Io.Dir.cwd().openFile(io, kernel, .{});
    defer image.close(io);
    if ((try image.stat(io)).kind != .file) return error.InvalidKernelImage;
    var header: [1024]u8 = undefined;
    if (try image.readPositionalAll(io, &header, 0) != header.len or !std.mem.eql(u8, header[0x202..0x206], "HdrS")) return error.KernelMustBeBzImage;
    const offset: u64 = 0x200 + @as(u64, std.mem.readInt(u16, header[0x20e..0x210], .little));
    var version: [256]u8 = undefined;
    const count = try image.readPositionalAll(io, &version, offset);
    const end = std.mem.indexOfAny(u8, version[0..count], " \x00\n") orelse return error.KernelVersionUnavailable;
    if (!std.mem.eql(u8, version[0..end], metadata.kernel_version)) return error.KernelModulesVersionMismatch;
    return metadata;
}

pub fn stage(a: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, kernel: []const u8, initrd: []const u8, request: session.Request, plan: []const u8) !void {
    const metadata = try validate(a, io, kernel, initrd);
    const kernel_digest = try fs.hashFileSha256(a, io, kernel);
    try std.Io.Dir.cwd().copyFile(kernel, directory, "kernel", io, .{ .permissions = .fromMode(0o600) });
    try std.Io.Dir.cwd().copyFile(initrd, directory, "maint.img", io, .{ .permissions = .fromMode(0o600) });
    const staged_kernel = try directory.openFile(io, "kernel", .{});
    defer staged_kernel.close(io);
    const staged_image = try directory.openFile(io, "maint.img", .{});
    defer staged_image.close(io);
    if (!std.mem.eql(u8, metadata.image_sha256, try fileDigest(a, io, staged_image)) or !std.mem.eql(u8, kernel_digest, try fileDigest(a, io, staged_kernel))) return error.InputChangedDuringStaging;
    const overlay = try archive.archive(a, &.{
        .{ .name = "etc", .mode = 0o040755 },
        .{ .name = "etc/pizza", .mode = 0o040700 },
        .{ .name = "etc/pizza/session.json", .mode = 0o100600, .data = try std.json.Stringify.valueAlloc(a, request, .{}) },
        .{ .name = "etc/pizza/plan.json", .mode = 0o100600, .data = plan },
    });
    const file = try directory.openFile(io, "maint.img", .{ .mode = .read_write });
    defer file.close(io);
    try file.writePositionalAll(io, overlay, (try file.stat(io)).size);
    try file.sync(io);
    try session.syncDir(io, directory);
}

fn fileDigest(a: std.mem.Allocator, io: std.Io, file: std.Io.File) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositionalAll(io, &buffer, offset);
        hash.update(buffer[0..count]);
        offset += count;
        if (count < buffer.len) break;
    }
    return a.dupe(u8, &std.fmt.bytesToHex(hash.finalResult(), .lower));
}

test "staging rejects changed images and mismatched kernel module releases" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try fs.createTemporaryDirectory(a, io, "pizza-image-validation-");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const initrd = try a.print("{s}/image", .{root});
    const kernel = try a.print("{s}/kernel", .{root});
    var bytes: [1024]u8 = @splat(0);
    @memcpy(bytes[0x202..0x206], "HdrS");
    std.mem.writeInt(u16, bytes[0x20e..0x210], 0x80, .little);
    @memcpy(bytes[0x280..0x285], "6.1.0");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = kernel, .data = &bytes });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = initrd, .data = "maintenance fixture" });
    const metadata: Metadata = .{ .version = 1, .kernel_version = "6.1.0", .image_sha256 = try fs.hashFileSha256(a, io, initrd) };
    const metadata_path = try a.print("{s}.pizza.json", .{initrd});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = try std.json.Stringify.valueAlloc(a, metadata, .{}) });
    _ = try validate(a, io, kernel, initrd);
    bytes[0x284] = '1';
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = kernel, .data = &bytes });
    try std.testing.expectError(error.KernelModulesVersionMismatch, validate(a, io, kernel, initrd));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = initrd, .data = "tampered" });
    try std.testing.expectError(error.MaintenanceImageHashMismatch, validate(a, io, kernel, initrd));
}
