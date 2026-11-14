//! Transport is curl; selection, resume ownership, integrity and caching are Zig.
const std = @import("std");
const vm_common = @import("vm_common");
const config_api = @import("image_config.zig");
const cli = @import("cli.zig");

pub fn digest(io: std.Io, path: []const u8) !struct { size: u64, sha256: [64]u8 } {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var size: u64 = 0;
    var buffer: [128 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        hasher.update(buffer[0..n]);
        size += n;
    }
    return .{ .size = size, .sha256 = std.fmt.bytesToHex(hasher.finalResult(), .lower) };
}
test "cached image verification rejects both content corruption and truncation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &buffer);
    const path = try std.fs.path.join(a, &.{ buffer[0..length], "fixture.iso" });
    defer a.free(path);
    const image: config_api.Image = .{ .id = "fixture", .variant = "fixture", .architecture = "x86_64", .url = "https://example.com/fixture.iso", .source_page = "https://example.com", .filename = "fixture.iso", .size = 3, .sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", .required_capabilities = &.{} };
    try temp.dir.writeFile(io, .{ .sub_path = "fixture.iso", .data = "abc" });
    try verify(io, image, path);
    try temp.dir.writeFile(io, .{ .sub_path = "fixture.iso", .data = "abd" });
    try std.testing.expectError(error.ImageChecksumMismatch, verify(io, image, path));
    try temp.dir.writeFile(io, .{ .sub_path = "fixture.iso", .data = "ab" });
    try std.testing.expectError(error.ImageSizeMismatch, verify(io, image, path));
}
fn verify(io: std.Io, image: config_api.Image, path: []const u8) !void {
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (st.size != image.size) return error.ImageSizeMismatch;
    const actual = try digest(io, path);
    if (actual.size != image.size) return error.ImageSizeMismatch;
    if (!std.ascii.eqlIgnoreCase(&actual.sha256, image.sha256)) {
        std.debug.print("Image SHA-256: expected {s}, got {s}\n", .{ image.sha256, actual.sha256 });
        return error.ImageChecksumMismatch;
    }
}
fn exists(io: std.Io, path: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}
const Segment = struct { path: []const u8, offset: u64, length: u64 };
const Segments = struct { image: config_api.Image, prefix: u64, parts: []const Segment };
// Keep completed bytes even when another parallel connection is interrupted.
// A separate tail and its HTTP Content-Range make an interrupted append replayable.
fn mergeTail(a: std.mem.Allocator, io: std.Io, part: Segment, total: u64) !void {
    const tail = try a.print("{s}.next", .{part.path});
    if (!try exists(io, tail)) return;
    const header = try a.print("{s}.headers", .{tail});
    if ((try std.Io.Dir.cwd().statFile(io, tail, .{})).size == 0) {
        try std.Io.Dir.cwd().deleteFile(io, tail);
        std.Io.Dir.cwd().deleteFile(io, header) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }
    const headers = try std.Io.Dir.cwd().readFileAlloc(io, header, a, .limited(512 * 1024 * 1024));
    var range: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |line_| {
        const line = std.mem.trim(u8, line_, "\r \t");
        if (std.mem.startsWith(u8, line, "HTTP/")) range = null;
        if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..15], "content-range: ")) range = line[15..];
    }
    const value = range orelse return error.MissingContentRange;
    if (!std.mem.startsWith(u8, value, "bytes ")) return error.InvalidContentRange;
    var bounds = std.mem.tokenizeAny(u8, value[6..], "-/");
    const first = try std.fmt.parseInt(u64, bounds.next() orelse return error.InvalidContentRange, 10);
    const last = try std.fmt.parseInt(u64, bounds.next() orelse return error.InvalidContentRange, 10);
    const size = try std.fmt.parseInt(u64, bounds.next() orelse return error.InvalidContentRange, 10);
    if (bounds.next() != null or size != total or first < part.offset or last != part.offset + part.length - 1 or first > last) return error.InvalidContentRange;
    const offset = first - part.offset;
    const input = try std.Io.Dir.cwd().openFile(io, tail, .{});
    defer input.close(io);
    const length = (try input.stat(io)).size;
    if (length > part.length - offset) return error.ImageSizeMismatch;
    const output = try std.Io.Dir.cwd().createFile(io, part.path, .{ .truncate = false });
    {
        defer output.close(io);
        const prior = (try output.stat(io)).size;
        if (prior < offset or prior > offset + length) return error.PartialImageSourceMismatch;
        var written: u64 = 0;
        var buf: [128 * 1024]u8 = undefined;
        while (written < length) {
            const n = try input.readStreaming(io, &.{&buf});
            if (n == 0 or n > length - written) return error.ImageSizeMismatch;
            try output.writePositionalAll(io, buf[0..n], offset + written);
            written += n;
        }
        try output.sync(io);
    }
    try std.Io.Dir.cwd().deleteFile(io, tail);
    try std.Io.Dir.cwd().deleteFile(io, header);
}
test "range resume replays an interrupted append and rejects a foreign extent" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buf: [4096]u8 = undefined;
    const n = try temp.dir.realPath(io, &buf);
    const part: Segment = .{ .path = try std.fs.path.join(alloc, &.{ buf[0..n], "part" }), .offset = 5, .length = 6 };
    // One byte was appended before a crash; the whole tail must be replayable.
    try temp.dir.writeFile(io, .{ .sub_path = "part", .data = "abcd" });
    try temp.dir.writeFile(io, .{ .sub_path = "part.next", .data = "def" });
    try temp.dir.writeFile(io, .{ .sub_path = "part.next.headers", .data = "HTTP/2 302\r\n\r\nHTTP/2 206\r\ncontent-range: bytes 8-10/11\r\n\r\n" });
    try mergeTail(alloc, io, part, 11);
    try std.testing.expectEqualStrings("abcdef", try std.Io.Dir.cwd().readFileAlloc(io, part.path, alloc, .limited(512 * 1024 * 1024)));
    try temp.dir.writeFile(io, .{ .sub_path = "part.next", .data = "wrong" });
    try temp.dir.writeFile(io, .{ .sub_path = "part.next.headers", .data = "HTTP/2 206\r\nContent-Range: bytes 1-5/11\r\n\r\n" });
    try std.testing.expectError(error.InvalidContentRange, mergeTail(alloc, io, part, 11));
    try std.testing.expectEqualStrings("abcdef", try std.Io.Dir.cwd().readFileAlloc(io, part.path, alloc, .limited(512 * 1024 * 1024)));
}
// curl's default retry policy excludes TLS read failures. Retry those at the
// segment layer so every interrupted tail is range-checked before resuming.
fn retryableTransfer(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| switch (code) {
            5, 6, 7, 18, 28, 35, 42, 52, 55, 56, 92 => true,
            else => false,
        },
        else => false,
    };
}
test "TLS interruption resumes verified ranges while HTTP refusal remains fatal" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try temp.dir.realPath(io, &buffer);
    const root = buffer[0..n];
    const curl = try temp.dir.createFile(io, "curl", .{});
    {
        defer curl.close(io);
        try curl.writeStreamingAll(io,
            \\#!/usr/bin/python3
            \\import os, pathlib, sys
            \\count = pathlib.Path(__file__).with_name('calls')
            \\attempt = int(count.read_text()) if count.exists() else 0
            \\count.write_text(str(attempt + 1))
            \\size = int(os.environ['SIZE'])
            \\if os.environ.get('FATAL'): sys.exit(22)
            \\groups = [[]]
            \\for arg in sys.argv[1:]:
            \\    if arg == '--next': groups.append([])
            \\    else: groups[-1].append(arg)
            \\ranges = []
            \\for index, args in enumerate(groups):
            \\    first, last = map(int, args[args.index('--range') + 1].split('-'))
            \\    header = pathlib.Path(args[args.index('--dump-header') + 1])
            \\    output = pathlib.Path(args[args.index('--output') + 1])
            \\    header.write_text(f'HTTP/2 206\r\nContent-Range: bytes {first}-{last}/{size}\r\n\r\n')
            \\    data = bytes(i % 251 for i in range(first, last + 1))
            \\    if os.environ.get('CORRUPT') and (attempt == 0 or os.environ['CORRUPT'] == 'always') and index == 0:
            \\        data = bytes([data[0] ^ 1]) + data[1:]
            \\    output.write_bytes(data[:2] if not os.environ.get('CORRUPT') and attempt == 0 and index == 0 else data)
            \\    ranges.append(f'{first}-{last}')
            \\with pathlib.Path(__file__).with_name('ranges').open('a') as log: log.write(','.join(ranges) + '\n')
            \\sys.exit(0 if (os.environ.get('MASKED_SUCCESS') or os.environ.get('CORRUPT')) else 56 if attempt == 0 else 0)
        );
        try curl.setPermissions(io, .executable_file);
    }
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    const transport = try std.fs.path.join(a, &.{ root, "curl" });
    var config = try config_api.Config.parse(a, @embedFile("images.json"));
    config.download.connections = 2;
    config.download.retries = 1;
    config.download.timeout_seconds = 10;
    var image = try config.select(null);
    const expected = try a.alloc(u8, 1024 * 1024 + 7);
    for (expected, 0..) |*byte, i| byte.* = @intCast(i % 251);
    image.size = expected.len;
    image.chunk_size = 0;
    image.chunk_sha256 = &.{};
    try env.put("SIZE", try a.print("{d}", .{expected.len}));
    image.url = "https://example.invalid/fixture.iso";
    const sha256 = vm_common.hash(expected);
    image.sha256 = &sha256;
    const partial = try std.fs.path.join(a, &.{ root, "fixture.partial" });
    try parallelDownload(a, io, &env, transport, config, image, partial);
    try verify(io, image, partial);
    try std.testing.expectEqualSlices(u8, expected, try std.Io.Dir.cwd().readFileAlloc(io, partial, a, .limited(2 * 1024 * 1024)));
    try std.testing.expectEqualStrings("2", try temp.dir.readFileAlloc(io, "calls", a, .limited(100)));
    try std.testing.expectEqualStrings("0-524291,524292-1048582\n2-524291\n", try temp.dir.readFileAlloc(io, "ranges", a, .limited(100)));
    try temp.dir.writeFile(io, .{ .sub_path = "calls", .data = "0" });
    try env.put("MASKED_SUCCESS", "1");
    const masked = try std.fs.path.join(a, &.{ root, "masked.partial" });
    try parallelDownload(a, io, &env, transport, config, image, masked);
    try verify(io, image, masked);
    try std.testing.expectEqualStrings("2", try temp.dir.readFileAlloc(io, "calls", a, .limited(100)));
    _ = env.swapRemove("MASKED_SUCCESS");
    try temp.dir.writeFile(io, .{ .sub_path = "calls", .data = "0" });
    try env.put("CORRUPT", "1");
    image.chunk_size = (image.size + 1) / 2;
    const first_sha = vm_common.hash(expected[0..@intCast(image.chunk_size)]);
    const last_sha = vm_common.hash(expected[@intCast(image.chunk_size)..]);
    image.chunk_sha256 = &.{ &first_sha, &last_sha };
    const corrupt = try std.fs.path.join(a, &.{ root, "corrupt.partial" });
    try parallelDownload(a, io, &env, transport, config, image, corrupt);
    try verify(io, image, corrupt);
    try std.testing.expectEqualStrings("2", try temp.dir.readFileAlloc(io, "calls", a, .limited(100)));
    try temp.dir.writeFile(io, .{ .sub_path = "calls", .data = "0" });
    try env.put("CORRUPT", "always");
    const unrecoverable = try std.fs.path.join(a, &.{ root, "unrecoverable.partial" });
    try std.testing.expectError(error.ImageDownloadIncomplete, parallelDownload(a, io, &env, transport, config, image, unrecoverable));
    try std.testing.expectEqualStrings("2", try temp.dir.readFileAlloc(io, "calls", a, .limited(100)));
    try std.testing.expect(!try exists(io, unrecoverable));
    _ = env.swapRemove("CORRUPT");
    image.chunk_size = 0;
    image.chunk_sha256 = &.{};
    try temp.dir.writeFile(io, .{ .sub_path = "calls", .data = "0" });
    try env.put("FATAL", "1");
    const refused = try std.fs.path.join(a, &.{ root, "refused.partial" });
    try std.testing.expectError(error.CommandFailed, parallelDownload(a, io, &env, transport, config, image, refused));
    try std.testing.expectEqualStrings("1", try temp.dir.readFileAlloc(io, "calls", a, .limited(100)));
    // The real multi-gigabyte ISO must not require long-lived 490 MB ranges.
    image.size = 3928064000;
    const large = try std.fs.path.join(a, &.{ root, "large.partial" });
    try std.testing.expectError(error.CommandFailed, parallelDownload(a, io, &env, transport, config, image, large));
    const plan = try std.json.parseFromSliceLeaky(Segments, a, try std.Io.Dir.cwd().readFileAlloc(io, try a.print("{s}.segments.json", .{large}), a, .limited(1024 * 1024)), .{});
    try std.testing.expect(plan.parts.len > config.download.connections);
    var total: u64 = 0;
    for (plan.parts) |part| {
        try std.testing.expect(part.length <= 64 * 1024 * 1024);
        total += part.length;
    }
    try std.testing.expectEqual(image.size, total);
}
// A complete HTTP range can still contain corrupt bytes. Keep good chunks and
// retry only the affected extent; the whole-image digest remains authoritative.
fn verifyOrResetChunk(io: std.Io, part: Segment, image: config_api.Image) !bool {
    if (image.chunk_sha256.len == 0) return true;
    const expected = image.chunk_sha256[@intCast(part.offset / image.chunk_size)];
    const actual = try digest(io, part.path);
    if (std.ascii.eqlIgnoreCase(expected, &actual.sha256)) return true;
    std.debug.print("Corrupt image range {d}-{d}: expected {s}, got {s}; retrying this range\n", .{ part.offset, part.offset + part.length - 1, expected, actual.sha256 });
    const file = try std.Io.Dir.cwd().createFile(io, part.path, .{});
    file.close(io);
    return false;
}
fn parallelDownload(a: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, transport: []const u8, config: config_api.Config, image: config_api.Image, partial: []const u8) !void {
    const manifest = try a.print("{s}.segments.json", .{partial});
    const plan = if (try exists(io, manifest)) blk: {
        const prior = try std.json.parseFromSliceLeaky(Segments, a, try std.Io.Dir.cwd().readFileAlloc(io, manifest, a, .limited(512 * 1024 * 1024)), .{});
        if (!std.mem.eql(u8, try std.json.Stringify.valueAlloc(a, prior.image, .{ .whitespace = .indent_2 }), try std.json.Stringify.valueAlloc(a, image, .{ .whitespace = .indent_2 }))) return error.PartialImageSourceMismatch;
        break :blk prior;
    } else blk: {
        const prefix = if (image.chunk_sha256.len > 0) 0 else if (try exists(io, partial)) (try std.Io.Dir.cwd().statFile(io, partial, .{})).size else 0;
        if (prefix == image.size) return;
        if (prefix > image.size) return error.PartialImageSourceMismatch;
        const remaining = image.size - prefix;
        // Bound each request's lifetime; the mirror repeatedly truncated the
        // former ~490 MB ranges in hosted CI. Concurrency remains independent.
        const chunk = if (image.chunk_sha256.len > 0) image.chunk_size else @min(64 * 1024 * 1024, try std.math.divCeil(u64, remaining, config.download.connections));
        const count = try std.math.divCeil(u64, remaining, chunk);
        if (count > 4096) return error.InvalidSegmentManifest;
        const parts = try a.alloc(Segment, @intCast(count));
        for (parts, 0..) |*part, index| {
            const offset = @min(image.size, prefix + index * chunk);
            part.* = .{ .path = try a.print("{s}.part-{d}", .{ partial, index }), .offset = offset, .length = @min(chunk, image.size - offset) };
        }
        const new: Segments = .{ .image = image, .prefix = prefix, .parts = parts };
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = try std.json.Stringify.valueAlloc(a, new, .{ .whitespace = .indent_2 }) });
        break :blk new;
    };
    // The segment manifest is cache data: validate every filename and extent
    // before opening or deleting anything that it names.
    if (plan.prefix > image.size or plan.parts.len == 0 or plan.parts.len > 4096) return error.InvalidSegmentManifest;
    var cursor = plan.prefix;
    for (plan.parts, 0..) |part, index| {
        if (!std.mem.eql(u8, part.path, try a.print("{s}.part-{d}", .{ partial, index })) or part.offset != cursor or part.length > image.size - cursor) return error.InvalidSegmentManifest;
        if (image.chunk_sha256.len > 0 and (part.offset % image.chunk_size != 0 or part.length != @min(image.chunk_size, image.size - part.offset))) return error.InvalidSegmentManifest;
        cursor += part.length;
    }
    if (cursor != image.size) return error.InvalidSegmentManifest;
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ transport, "--parallel", "--parallel-immediate", "--parallel-max", try a.print("{d}", .{config.download.connections}) });
        var transfers: usize = 0;
        for (plan.parts) |part| {
            if (part.length == 0) continue;
            try mergeTail(a, io, part, image.size);
            var have = if (try exists(io, part.path)) (try std.Io.Dir.cwd().statFile(io, part.path, .{})).size else 0;
            if (have > part.length) return error.ImageSizeMismatch;
            if (have == part.length) {
                if (try verifyOrResetChunk(io, part, image)) continue;
                have = 0;
            }
            if (transfers > 0) try argv.append(a, "--next");
            const tail = try a.print("{s}.next", .{part.path});
            try argv.appendSlice(a, &.{ "--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https", "--retry", try a.print("{d}", .{config.download.retries}), "--connect-timeout", try a.print("{d}", .{config.download.connect_timeout_seconds}), "--max-time", try a.print("{d}", .{config.download.timeout_seconds}), "--max-filesize", try a.print("{d}", .{part.length - have}), "--range", try a.print("{d}-{d}", .{ part.offset + have, part.offset + part.length - 1 }), "--dump-header", try a.print("{s}.headers", .{tail}), "--output", tail, "--url", image.url });
            transfers += 1;
        }
        if (transfers == 0) break;
        {
            const result = try vm_common.runAt(a, io, env, .inherit, argv.items, null, config.download.timeout_seconds + 60);
            var complete = true;
            for (plan.parts) |part| {
                if (part.length == 0) continue;
                try mergeTail(a, io, part, image.size);
                const have = if (try exists(io, part.path)) (try std.Io.Dir.cwd().statFile(io, part.path, .{})).size else 0;
                if (have != part.length or !try verifyOrResetChunk(io, part, image)) complete = false;
            }
            // With multiple URLs curl can return success for the last transfer
            // even when an earlier range failed. Inspect every segment as well.
            if (result.term.success() and complete) break;
            if (!result.term.success() and !retryableTransfer(result.term))
                _ = try vm_common.check(result);
            std.debug.print("Incomplete image transfer ({f}); verified ranges retained, attempt {d}/{d}\n{s}\n", .{ result.term, attempt + 1, config.download.retries + 1, result.stderr });
            if (attempt >= config.download.retries) {
                _ = try vm_common.check(result);
                return error.ImageDownloadIncomplete;
            }
            try std.Io.sleep(io, .fromSeconds(2), .awake);
        }
    }
    const output = try std.Io.Dir.cwd().createFile(io, partial, .{ .truncate = false });
    defer output.close(io);
    if ((try output.stat(io)).size < plan.prefix) return error.PartialImageSourceMismatch;
    for (plan.parts) |part| {
        if (part.length == 0) continue;
        const input = try std.Io.Dir.cwd().openFile(io, part.path, .{});
        defer input.close(io);
        if ((try input.stat(io)).size != part.length) return error.ImageSizeMismatch;
        var offset = part.offset;
        var buffer: [128 * 1024]u8 = undefined;
        while (offset < part.offset + part.length) {
            const n = try input.readStreaming(io, &.{&buffer});
            if (n == 0 or n > part.offset + part.length - offset) return error.ImageSizeMismatch;
            try output.writePositionalAll(io, buffer[0..n], offset);
            offset += n;
        }
    }
    try output.sync(io);
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var parsed = try cli.Fetch.parse(a, args[1..]);
    defer parsed.deinit();
    const options = parsed.args;
    if (options.help != 0) return cli.help(io, cli.Fetch);
    const path = options.config orelse "test/windows-vm/images.json";
    const id = options.image;
    const out = options.out;
    const verify_only = options.@"verify-only" != 0;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(512 * 1024 * 1024));
    const config = try config_api.Config.parse(a, bytes);
    const image = try config.select(id);
    const directory = out orelse config.download.cache_dir;
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const final = try std.fs.path.join(a, &.{ directory, image.filename });
    const lock = try std.Io.Dir.cwd().createFile(io, try a.print("{s}.lock", .{final}), .{ .truncate = false });
    defer lock.close(io);
    if (!(try lock.tryLock(io, .exclusive))) return error.ImageDownloadAlreadyRunning;
    defer lock.unlock(io);
    if (try exists(io, final)) {
        try verify(io, image, final);
        std.debug.print("Verified cached image: {s}\n", .{final});
        return;
    }
    if (verify_only) return error.ImageNotCached;
    const partial = try a.print("{s}.partial", .{final});
    const receipt = try a.print("{s}.source.json", .{partial});
    const identity = try std.json.Stringify.valueAlloc(a, image, .{ .whitespace = .indent_2 });
    if (try exists(io, partial)) {
        if (!(try exists(io, receipt))) return error.PartialImageSourceMismatch;
        const prior = try std.json.parseFromSliceLeaky(config_api.Image, a, try std.Io.Dir.cwd().readFileAlloc(io, receipt, a, .limited(512 * 1024 * 1024)), .{});
        if (!std.mem.eql(u8, try std.json.Stringify.valueAlloc(a, prior, .{ .whitespace = .indent_2 }), identity)) return error.PartialImageSourceMismatch;
        const st = try std.Io.Dir.cwd().statFile(io, partial, .{});
        if (st.size > image.size) return error.ImageSizeMismatch;
    } else try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = receipt, .data = identity });
    std.debug.print("Fetching {s} ({d} bytes); source: {s}\n", .{ image.id, image.size, image.source_page });
    if (config.download.connections > 1) try parallelDownload(a, io, init.environ_map, "curl", config, image, partial) else if (!(try exists(io, partial)) or (try std.Io.Dir.cwd().statFile(io, partial, .{})).size != image.size) _ = try vm_common.check(try vm_common.runAt(a, io, init.environ_map, .inherit, &.{
        "curl",    "--fail",                                       "--location",        "--silent",                                                     "--show-error", "--proto",                                              "=https",         "--proto-redir",                   "=https",
        "--retry", try a.print("{d}", .{config.download.retries}), "--connect-timeout", try a.print("{d}", .{config.download.connect_timeout_seconds}), "--max-time",   try a.print("{d}", .{config.download.timeout_seconds}), "--max-filesize", try a.print("{d}", .{image.size}), "--continue-at",
        "-",       "--output",                                     partial,             "--url",                                                        image.url,
    }, null, config.download.timeout_seconds + 60));
    try verify(io, image, partial);
    const file = try std.Io.Dir.cwd().openFile(io, partial, .{});
    try file.sync(io);
    file.close(io);
    try std.Io.Dir.cwd().rename(partial, std.Io.Dir.cwd(), final, io);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try a.print("{s}.verified.json", .{final}), .data = try std.json.Stringify.valueAlloc(a, .{ .image = image, .download = try digest(io, final), .config_sha256 = vm_common.hash(bytes) }, .{ .whitespace = .indent_2 }) });
    const segments = try a.print("{s}.segments.json", .{partial});
    if (try exists(io, segments)) {
        const plan = try std.json.parseFromSliceLeaky(Segments, a, try std.Io.Dir.cwd().readFileAlloc(io, segments, a, .limited(512 * 1024 * 1024)), .{});
        for (plan.parts, 0..) |part, index| {
            if (!std.mem.eql(u8, part.path, try a.print("{s}.part-{d}", .{ partial, index }))) return error.InvalidSegmentManifest;
            if (try exists(io, part.path)) try std.Io.Dir.cwd().deleteFile(io, part.path);
        }
        try std.Io.Dir.cwd().deleteFile(io, segments);
    }
    std.debug.print("Verified image: {s}\n", .{final});
}
