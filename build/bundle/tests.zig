//! Bundle trust and archive behavior, exercised by zig build test.
const std = @import("std");
const utils = @import("utils");
const release = @import("release.zig");
const archive = @import("archive.zig");
const files = @import("files.zig");

test "release policy pins publisher identity, artifact names and source ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lock = try release.readLock(a, std.testing.io, release.lock_path);
    var bad = lock;
    bad.repository = "attacker/pizza-bundle";
    try std.testing.expectError(error.InvalidReleaseLock, bad.validate());
    bad = lock;
    bad.repository_id = "123";
    try std.testing.expectError(error.InvalidReleaseLock, bad.validate());
    bad = lock;
    bad.tag = "v1/../../main";
    try std.testing.expectError(error.InvalidReleaseLock, bad.validate());
    bad = lock;
    bad.kernel_asset = "--unsafe";
    try std.testing.expectError(error.InvalidReleaseLock, bad.validate());
}

test "modified release bytes are rejected before signature verification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try utils.filesystem.createTemporaryDirectory(a, io, "pizza-trust-");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var lock = try release.readLock(a, io, release.lock_path);
    lock.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try files.join(a, &.{ root, lock.asset }), .data = "modified" });
    var env: std.process.Environ.Map = .init(a);
    try env.put("PATH", "/nonexistent");
    try std.testing.expectError(error.ReleaseDigestMismatch, release.verify(a, io, &env, root, lock));
}

test "application newc preserves executable and relative symlink and is deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try utils.filesystem.createTemporaryDirectory(a, io, "pizza-layer-");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const overlay = try files.join(a, &.{ root, "overlay" });
    const panel = try files.join(a, &.{ overlay, "opt/pizza/panel" });
    try std.Io.Dir.cwd().createDirPath(io, panel);
    const init = try std.Io.Dir.cwd().createFile(io, try files.join(a, &.{ overlay, "init" }), .{ .permissions = .fromMode(0o755) });
    try init.writePositionalAll(io, "application", 0);
    init.close(io);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try files.join(a, &.{ panel, "index.html" }), .data = "panel" });
    try std.Io.Dir.cwd().symLink(io, "opt/pizza/panel", try files.join(a, &.{ overlay, "panel-link" }), .{});
    var env: std.process.Environ.Map = .init(a);
    try env.put("PATH", "/usr/bin:/bin");
    const first = try files.join(a, &.{ root, "first.cpio" });
    const second = try files.join(a, &.{ root, "second.cpio" });
    try archive.layer(a, io, &env, overlay, first);
    try std.Io.Dir.cwd().setTimestampsNow(io, try files.join(a, &.{ overlay, "init" }), .{});
    try archive.layer(a, io, &env, overlay, second);
    try std.testing.expectEqualStrings(try utils.filesystem.hashFileSha256(a, io, first), try utils.filesystem.hashFileSha256(a, io, second));
    const restored = try files.join(a, &.{ root, "restored" });
    try std.Io.Dir.cwd().createDirPath(io, restored);
    try utils.process.runInherited(io, &env, &.{ "bsdtar", "-xf", first, "--no-same-owner", "-C", restored });
    try std.testing.expectEqualStrings("panel", try std.Io.Dir.cwd().readFileAlloc(io, try files.join(a, &.{ restored, "panel-link/index.html" }), a, .limited(100)));
    try std.Io.Dir.cwd().access(io, try files.join(a, &.{ restored, "init" }), .{ .execute = true });
    try std.Io.Dir.cwd().symLink(io, "/etc/passwd", try files.join(a, &.{ overlay, "external" }), .{});
    try std.testing.expectError(error.EscapingSymlink, archive.layer(a, io, &env, overlay, try files.join(a, &.{ root, "bad.cpio" })));
}

test "output refuses existing data and publishes atomically without replacing a competing writer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try utils.filesystem.createTemporaryDirectory(a, io, "pizza-output-");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const target = try files.join(a, &.{ root, "result" });
    const output = try files.Output.init(a, io, target, false);
    defer output.deinit(io);
    const candidate = try files.join(a, &.{ output.temporary, "file" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = candidate, .data = "new" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = "existing" });
    try std.testing.expectError(error.PathAlreadyExists, output.publish(io, candidate));
    try std.testing.expectError(error.OutputAlreadyExists, files.Output.init(a, io, target, false));
    try std.testing.expectEqualStrings("existing", try std.Io.Dir.cwd().readFileAlloc(io, target, a, .limited(100)));
}

const sigstore = @import("sigstore.zig");
const encoding = @import("encoding.zig");
const certificate = @import("certificate.zig");
const fixture_path = "test/fixtures/sigstore/pizza-bundle-v0.3.1.json";
const signed_time = 1792416063;
fn policy(lock: release.Lock) sigstore.Policy {
    return .{ .repository = lock.repository, .repository_id = lock.repository_id, .workflow = lock.workflow, .tag = lock.tag, .commit = lock.commit };
}
fn assets(lock: release.Lock) [3][2][]const u8 {
    return .{ .{ lock.asset, lock.sha256 }, .{ lock.kernel_asset, lock.kernel_sha256 }, .{ lock.metadata_asset, lock.metadata_sha256 } };
}
fn rejected(a: std.mem.Allocator, bytes: []const u8, identity: sigstore.Policy, subjects: []const [2][]const u8, now: u64) !void {
    if (sigstore.verify(a, bytes, identity, subjects, now)) |_| return error.ForgedAttestationAccepted else |_| {}
}
fn change(a: std.mem.Allocator, bytes: []const u8, path: []const []const u8, value: encoding.Value) ![]const u8 {
    var root = try encoding.json(a, bytes);
    var current: *encoding.Value = &root;
    for (path[0 .. path.len - 1]) |key| current = if (current.* == .array) &current.array.items[try std.fmt.parseInt(usize, key, 10)] else current.object.getPtr(key) orelse return error.MissingField;
    try current.object.put(a, path[path.len - 1], value);
    return std.json.Stringify.valueAlloc(a, root, .{});
}
fn altered(a: std.mem.Allocator, bytes: []const u8, path: []const []const u8) ![]const u8 {
    var value = try encoding.json(a, bytes);
    for (path) |key| value = if (value == .array) value.array.items[try std.fmt.parseInt(usize, key, 10)] else try encoding.field(value, key);
    const raw = try encoding.decode(a, try encoding.string(value));
    raw[raw.len / 2] ^= 1;
    return change(a, bytes, path, .{ .string = try encoding.encode(a, raw) });
}

test "native Sigstore authenticates the actual published bundle without subprocesses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lock = try release.readLock(a, std.testing.io, "test/fixtures/sigstore/pizza-bundle-v0.3.1.lock.json");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture_path, a, .limited(1024 * 1024));
    try sigstore.verify(a, bytes, policy(lock), &assets(lock), signed_time + 86400);
    // Certificate has expired at verification time: its authenticated signing time is used.
    try rejected(a, bytes, policy(lock), &assets(lock), signed_time - 1);
    var bad = policy(lock);
    bad.repository_id = "123";
    try rejected(a, bytes, bad, &assets(lock), signed_time + 86400);
    bad = policy(lock);
    bad.tag = "v999";
    try rejected(a, bytes, bad, &assets(lock), signed_time + 86400);
    bad = policy(lock);
    bad.commit = "0000000000000000000000000000000000000000";
    try rejected(a, bytes, bad, &assets(lock), signed_time + 86400);
    bad = policy(lock);
    bad.repository = "attacker/pizza-bundle";
    try rejected(a, bytes, bad, &assets(lock), signed_time + 86400);
    bad = policy(lock);
    bad.workflow = "Pizza-Partition/pizza-bundle/.github/workflows/other.yml";
    try rejected(a, bytes, bad, &assets(lock), signed_time + 86400);
    var wrong_assets = assets(lock);
    wrong_assets[0][1] = lock.kernel_sha256;
    try rejected(a, bytes, policy(lock), &wrong_assets, signed_time + 86400);
}

test "native Sigstore rejects tampered signatures, certificates, logs, proofs and identity material" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lock = try release.readLock(a, std.testing.io, "test/fixtures/sigstore/pizza-bundle-v0.3.1.lock.json");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture_path, a, .limited(1024 * 1024));
    for ([_][]const []const u8{
        &.{ "dsseEnvelope", "payload" },                                                &.{ "dsseEnvelope", "signatures", "0", "sig" },
        &.{ "verificationMaterial", "certificate", "rawBytes" },                        &.{ "verificationMaterial", "tlogEntries", "0", "canonicalizedBody" },
        &.{ "verificationMaterial", "tlogEntries", "0", "logId", "keyId" },             &.{ "verificationMaterial", "tlogEntries", "0", "inclusionPromise", "signedEntryTimestamp" },
        &.{ "verificationMaterial", "tlogEntries", "0", "inclusionProof", "rootHash" },
    }) |path| try rejected(a, try altered(a, bytes, path), policy(lock), &assets(lock), signed_time + 86400);
    for ([_][]const []const u8{
        &.{ "verificationMaterial", "tlogEntries", "0", "integratedTime" },
        &.{ "verificationMaterial", "tlogEntries", "0", "logIndex" },
        &.{ "verificationMaterial", "tlogEntries", "0", "inclusionProof", "logIndex" },
        &.{ "verificationMaterial", "tlogEntries", "0", "inclusionProof", "treeSize" },
    }) |path| try rejected(a, try change(a, bytes, path, .{ .string = "1" }), policy(lock), &assets(lock), signed_time + 86400);
    const root = try encoding.json(a, bytes);
    const material = try encoding.field(root, "verificationMaterial");
    const entries = try encoding.array(try encoding.field(material, "tlogEntries"));
    const proof = try encoding.field(entries[0], "inclusionProof");
    var checkpoint = try a.dupe(u8, try encoding.text(try encoding.field(proof, "checkpoint"), "envelope"));
    checkpoint[checkpoint.len - 8] ^= 1;
    try rejected(a, try change(a, bytes, &.{ "verificationMaterial", "tlogEntries", "0", "inclusionProof", "checkpoint", "envelope" }, .{ .string = checkpoint }), policy(lock), &assets(lock), signed_time + 86400);
    var hashes = try encoding.array(try encoding.field(proof, "hashes"));
    hashes[0] = .{ .string = hashes[1].string };
    try rejected(a, try change(a, bytes, &.{ "verificationMaterial", "tlogEntries", "0", "inclusionProof", "hashes" }, .{ .array = std.array_list.Managed(encoding.Value).fromOwnedSlice(a, hashes) }), policy(lock), &assets(lock), signed_time + 86400);
}

test "bounded certificate parser rejects every truncation without panicking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try encoding.json(a, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture_path, a, .limited(1024 * 1024)));
    const raw = try encoding.decode(a, try encoding.text(try encoding.field(try encoding.field(root, "verificationMaterial"), "certificate"), "rawBytes"));
    _ = try certificate.Certificate.parse(raw);
    for (0..raw.len) |len| if (certificate.Certificate.parse(raw[0..len])) |_| return error.TruncatedCertificateAccepted else |_| {};
}

test "native concatenation preserves opaque base bytes exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try utils.filesystem.createTemporaryDirectory(a, io, "pizza-append-");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const image = try files.join(a, &.{ root, "maint.img" });
    const layer = try files.join(a, &.{ root, "application.gz" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = image, .data = "opaque producer base" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = layer, .data = "application member" });
    try archive.appendFile(io, layer, image);
    try std.testing.expectEqualStrings("opaque producer baseapplication member", try std.Io.Dir.cwd().readFileAlloc(io, image, a, .limited(100)));
}

test "SCT signature verification is enforced independently of certificate signature verification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try encoding.json(a, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "build/bundle/trust/sigstore-public-good.json", a, .limited(1024 * 1024)));
    const fixture = try encoding.json(a, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture_path, a, .limited(1024 * 1024)));
    const raw = try encoding.decode(a, try encoding.text(try encoding.field(try encoding.field(fixture, "verificationMaterial"), "certificate"), "rawBytes"));
    const leaf = try certificate.Certificate.parse(raw);
    const authorities = try encoding.array(try encoding.field(root, "certificateAuthorities"));
    const chain = try encoding.array(try encoding.field(try encoding.field(authorities[1], "certChain"), "certificates"));
    const issuer = try certificate.Certificate.parse(try encoding.decode(a, try encoding.text(chain[0], "rawBytes")));
    try leaf.verify(issuer, signed_time);
    if (leaf.verify(issuer, signed_time + 86400)) |_| return error.ExpiredCertificateAccepted else |_| {}
    const transparency = @import("transparency.zig");
    try transparency.sct(a, root, leaf, issuer, signed_time + 86400);
    const extension = try leaf.extension(certificate.sct_oid);
    const offset = @intFromPtr(extension.ptr) - @intFromPtr(raw.ptr);
    raw[offset + extension.len - 1] ^= 1;
    if (transparency.sct(a, root, try certificate.Certificate.parse(raw), issuer, signed_time + 86400)) |_| return error.ForgedSctAccepted else |_| {}
}

test "native tar gzip is deterministic, preserves executable links and long names, and matches libarchive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const parent = try utils.filesystem.createTemporaryDirectory(a, io, "pizza-native-tar-");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};
    const root = try files.join(a, &.{ parent, "package" });
    const overlay = try files.join(a, &.{ root, "overlay" });
    try std.Io.Dir.cwd().createDirPath(io, try files.join(a, &.{ overlay, "panel" }));
    for ([_][2][]const u8{ .{ "init", "init" }, .{ "app", "app" }, .{ "panel/index.html", "panel" } }) |entry| {
        const output = try std.Io.Dir.cwd().createFile(io, try files.join(a, &.{ overlay, entry[0] }), .{ .permissions = .fromMode(0o755) });
        try output.writePositionalAll(io, entry[1], 0);
        output.close(io);
    }
    const long_name = "overlay/" ++ @as([120]u8, @splat('a'));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try files.join(a, &.{ root, long_name }), .data = "long name" });
    try std.Io.Dir.cwd().symLink(io, "panel", try files.join(a, &.{ overlay, "panel-alias" }), .{});
    try files.writeJson(a, io, try files.join(a, &.{ root, "manifest.json" }), .{ .format = @as(u16, 3), .kind = "pizza-application", .layout = "base-plus-overlay", .architecture = "x86_64", .profile = "wpe-platform-v2", .working_directory = "bundle-root", .components = .{ .@"pizza-init" = "overlay/init", .@"pizza-maint" = "overlay/app", .@"panel-assets" = "overlay/panel/index.html" } });
    const first = try files.join(a, &.{ parent, "first.tar.gz" });
    const second = try files.join(a, &.{ parent, "second.tar.gz" });
    var env: std.process.Environ.Map = .init(a);
    try env.put("PATH", "/nonexistent");
    try archive.pack(a, io, &env, root, first);
    try std.Io.Dir.cwd().setTimestampsNow(io, try files.join(a, &.{ overlay, "init" }), .{});
    try archive.pack(a, io, &env, root, second);
    try std.testing.expectEqualStrings(try utils.filesystem.hashFileSha256(a, io, first), try utils.filesystem.hashFileSha256(a, io, second));
    const native = try files.join(a, &.{ parent, "native" });
    const independent = try files.join(a, &.{ parent, "libarchive" });
    try std.Io.Dir.cwd().createDirPath(io, native);
    try std.Io.Dir.cwd().createDirPath(io, independent);
    try utils.archive.extract(a, io, first, native, .gzip, null);
    try env.put("PATH", "/usr/bin:/bin");
    try utils.process.runInherited(io, &env, &.{ "bsdtar", "-xf", first, "--no-same-owner", "-C", independent });
    for ([_][]const u8{ native, independent }) |extracted| {
        try std.testing.expectEqualStrings("panel", try std.Io.Dir.cwd().readFileAlloc(io, try files.join(a, &.{ extracted, "overlay/panel-alias/index.html" }), a, .limited(100)));
        try std.testing.expectEqualStrings("long name", try std.Io.Dir.cwd().readFileAlloc(io, try files.join(a, &.{ extracted, long_name }), a, .limited(100)));
        try std.Io.Dir.cwd().access(io, try files.join(a, &.{ extracted, "overlay/init" }), .{ .execute = true });
    }
    const encoded = try std.Io.Dir.cwd().readFileAlloc(io, first, a, .limited(1024 * 1024));
    encoded[encoded.len - 8] ^= 1;
    const bad = try files.join(a, &.{ parent, "bad.tar.gz" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bad, .data = encoded });
    try std.testing.expectError(error.GzipChecksumMismatch, utils.archive.extract(a, io, bad, native, .gzip, null));
}

test "native tar extraction rejects traversal, escaping links and symlink parents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const parent = try utils.filesystem.createTemporaryDirectory(a, io, "pizza-tar-confinement-");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};
    for ([_][]const u8{ "/escape", "../escape", "safe/../../escape" }) |name| {
        var bytes: std.Io.Writer.Allocating = .init(a);
        var tar: std.tar.Writer = .{ .underlying_writer = &bytes.writer };
        try tar.writeFileBytes(name, "escape", .{});
        var input: std.Io.Reader = .fixed(bytes.written());
        try std.testing.expectError(error.UnsafeArchivePath, utils.archive.extractTar(a, io, &input, parent, null));
    }
    for ([_][]const u8{ "/etc", "../../escape" }) |target| {
        var bytes: std.Io.Writer.Allocating = .init(a);
        var tar: std.tar.Writer = .{ .underlying_writer = &bytes.writer };
        try tar.writeLink("alias", target, .{});
        var input: std.Io.Reader = .fixed(bytes.written());
        try std.testing.expectError(error.UnsafeArchiveLink, utils.archive.extractTar(a, io, &input, parent, null));
    }
    var bytes: std.Io.Writer.Allocating = .init(a);
    var tar: std.tar.Writer = .{ .underlying_writer = &bytes.writer };
    try tar.writeDir("inside", .{});
    try tar.writeLink("alias", "inside", .{});
    try tar.writeFileBytes("alias/file", "must not follow a link", .{});
    var input: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.ArchiveSymlinkParent, utils.archive.extractTar(a, io, &input, parent, null));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, try files.join(a, &.{ parent, "inside/file" }), .{}));
    input = .fixed(bytes.written());
    try std.testing.expectError(error.UnsafeArchivePath, utils.archive.extractTar(a, io, &input, parent, "expected-root"));
}
