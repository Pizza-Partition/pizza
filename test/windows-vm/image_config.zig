//! Image identity and transport policy live in JSON, independently of the runner.
const std = @import("std");
pub const Image = struct {
    id: []const u8,
    variant: []const u8,
    architecture: []const u8,
    url: []const u8,
    source_page: []const u8,
    filename: []const u8,
    size: u64,
    sha256: []const u8,
    chunk_size: u64 = 0,
    chunk_sha256: []const []const u8 = &.{},
    required_capabilities: []const []const u8,
};
pub const Config = struct {
    version: u32,
    default_image: []const u8,
    images: []const Image,
    download: struct {
        cache_dir: []const u8,
        retries: u8,
        connect_timeout_seconds: u16,
        timeout_seconds: u32,
        connections: u8 = 1,
    },
    pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Config {
        const config = try std.json.parseFromSliceLeaky(Config, a, bytes, .{});
        if (config.version != 1 or config.images.len == 0) return error.UnsupportedImageConfig;
        if (config.download.cache_dir.len == 0 or config.download.retries > 20 or config.download.connect_timeout_seconds == 0 or config.download.timeout_seconds == 0 or config.download.timeout_seconds > 86400) return error.InvalidDownloadPolicy;
        if (config.download.connections == 0 or config.download.connections > 16) return error.InvalidDownloadPolicy;
        for (config.images, 0..) |image, i| {
            if (!safeName(image.id) or !safeName(image.filename) or image.size == 0) return error.InvalidImageIdentity;
            if (!https(image.url) or !https(image.source_page)) return error.HttpsImageSourceRequired;
            try validateHash(image.sha256, 64);
            if (image.chunk_sha256.len > 0) {
                if (image.chunk_size == 0 or image.chunk_size > 64 * 1024 * 1024 or image.chunk_sha256.len > 4096 or try std.math.divCeil(u64, image.size, image.chunk_size) != image.chunk_sha256.len) return error.InvalidImageChunks;
                for (image.chunk_sha256) |checksum| try validateHash(checksum, 64);
            } else if (image.chunk_size != 0) return error.InvalidImageChunks;
            for (config.images[0..i]) |earlier| {
                if (std.mem.eql(u8, image.id, earlier.id)) return error.DuplicateImageId;
                if (std.mem.eql(u8, image.filename, earlier.filename)) return error.DuplicateImageFilename;
            }
        }
        _ = try config.select(null);
        return config;
    }
    pub fn select(config: Config, id: ?[]const u8) !Image {
        for (config.images) |image| if (std.mem.eql(u8, image.id, id orelse config.default_image)) return image;
        return error.UnknownImageId;
    }
};
fn validateHash(hash: []const u8, length: usize) !void {
    if (hash.len != length) return error.InvalidImageHash;
    for (hash) |ch| if (!std.ascii.isHex(ch)) return error.InvalidImageHash;
}
fn safeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 200 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '_') return false;
    return true;
}
fn https(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://") or url.len <= 8) return false;
    for (url) |ch| if (ch <= 32 or ch == 127) return false;
    return true;
}
test "repository image configuration is complete and selects its default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try Config.parse(arena.allocator(), @embedFile("images.json"));
    const image = try config.select(null);
    try std.testing.expect(image.required_capabilities.len > 0);
    try std.testing.expectError(error.UnknownImageId, config.select("missing"));
}
test "configuration rejects unpinned images and cache path escapes" {
    try std.testing.expect(!safeName("../base.iso"));
    try std.testing.expect(!safeName("/base.iso"));
    try std.testing.expect(!safeName("..\\base.iso"));
    try std.testing.expect(!https("http://example.com/base.iso"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = @embedFile("images.json");
    const needle = (try Config.parse(arena.allocator(), bytes)).images[0].sha256;
    const corrupted = try std.mem.replaceOwned(u8, arena.allocator(), bytes, needle, "no-hash");
    try std.testing.expectError(error.InvalidImageHash, Config.parse(arena.allocator(), corrupted));
}

test "chunk integrity metadata must cover exactly the locked image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var config = try Config.parse(a, @embedFile("images.json"));
    var images = [_]Image{config.images[0]};
    config.images = &images;
    const original = images[0];
    images[0].chunk_size = 0;
    try std.testing.expectError(error.InvalidImageChunks, Config.parse(a, try std.json.Stringify.valueAlloc(a, config, .{})));
    images[0] = original;
    images[0].chunk_sha256 = original.chunk_sha256[0 .. original.chunk_sha256.len - 1];
    try std.testing.expectError(error.InvalidImageChunks, Config.parse(a, try std.json.Stringify.valueAlloc(a, config, .{})));
    images[0].chunk_sha256 = &.{};
    try std.testing.expectError(error.InvalidImageChunks, Config.parse(a, try std.json.Stringify.valueAlloc(a, config, .{})));
    images[0].size = 1;
    images[0].chunk_sha256 = &.{"invalid"};
    try std.testing.expectError(error.InvalidImageHash, Config.parse(a, try std.json.Stringify.valueAlloc(a, config, .{})));
}
