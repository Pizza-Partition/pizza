//! Offline Rekor v1 inclusion verification and RFC 6962 certificate transparency.
const std = @import("std");
const e = @import("encoding.zig");
const certs = @import("certificate.zig");
const Value = e.Value;
const Key = certs.Key;

pub fn logKey(a: std.mem.Allocator, root: Value, collection: []const u8, id: []const u8, time: u64) !Key {
    for (try e.array(try e.field(root, collection))) |log| {
        if (!e.equal(try e.decode(a, try e.text(try e.field(log, "logId"), "keyId")), id)) continue;
        try e.require(e.equal(try e.text(log, "hashAlgorithm"), "SHA2_256"));
        const key = try e.field(log, "publicKey");
        try e.validAt(try e.field(key, "validFor"), time);
        try e.require(e.equal(try e.text(key, "keyDetails"), "PKIX_ECDSA_P256_SHA_256"));
        const spki = try e.decode(a, try e.text(key, "rawBytes"));
        try e.require(e.equal(&e.hash(spki), id));
        return Key.parse(spki);
    }
    return error.UntrustedTransparencyLog;
}

pub fn rekor(a: std.mem.Allocator, root: Value, entry: Value, payload: []const u8, signature: []const u8, certificate: []const u8, now: u64) !u64 {
    const kind = try e.field(entry, "kindVersion");
    try e.require(e.equal(try e.text(kind, "kind"), "dsse") and e.equal(try e.text(kind, "version"), "0.0.1"));
    const time = try e.number(try e.field(entry, "integratedTime"));
    try e.require(time <= now);
    const id = try e.decode(a, try e.text(try e.field(entry, "logId"), "keyId"));
    const key = try logKey(a, root, "tlogs", id, time);
    const body_encoded = try e.text(entry, "canonicalizedBody");
    const body = try e.decode(a, body_encoded);
    // SET uses RFC 8785 canonical JSON: these four known fields, in sorted order.
    const signed = try std.json.Stringify.valueAlloc(a, .{ .body = body_encoded, .integratedTime = time, .logID = std.fmt.bytesToHex(id[0..32].*, .lower), .logIndex = try e.number(try e.field(entry, "logIndex")) }, .{});
    try key.verify(try e.decode(a, try e.text(try e.field(entry, "inclusionPromise"), "signedEntryTimestamp")), signed);
    // Bind the authenticated log body to this exact payload, signature and leaf certificate.
    const record = try e.json(a, body);
    try e.require(e.equal(try e.text(record, "kind"), "dsse") and e.equal(try e.text(record, "apiVersion"), "0.0.1"));
    const spec = try e.field(record, "spec");
    const payload_hash = try e.field(spec, "payloadHash");
    try e.require(e.equal(try e.text(payload_hash, "algorithm"), "sha256") and e.equal(try e.text(payload_hash, "value"), &e.digest(payload)));
    const signatures = try e.array(try e.field(spec, "signatures"));
    try e.require(signatures.len == 1);
    try e.require(e.equal(try e.decode(a, try e.text(signatures[0], "signature")), signature));
    const pem = try e.decode(a, try e.text(signatures[0], "verifier"));
    const prefix = "-----BEGIN CERTIFICATE-----\n";
    const suffix = "-----END CERTIFICATE-----\n";
    try e.require(std.mem.startsWith(u8, pem, prefix) and std.mem.endsWith(u8, pem, suffix));
    const middle = pem[prefix.len .. pem.len - suffix.len];
    var compact: std.Io.Writer.Allocating = .init(a);
    for (middle) |b| if (b != '\n') try compact.writer.writeByte(b);
    try e.require(e.equal(try e.decode(a, compact.written()), certificate));
    try inclusion(a, key, id, body, try e.field(entry, "inclusionProof"));
    return time;
}

fn inclusion(a: std.mem.Allocator, key: Key, id: []const u8, body: []const u8, proof: Value) !void {
    var index = try e.number(try e.field(proof, "logIndex"));
    const size = try e.number(try e.field(proof, "treeSize"));
    try e.require(size > 0 and index < size);
    var last = size - 1;
    var hash = e.hash(try std.mem.concat(a, u8, &.{ &.{0}, body }));
    const path = try e.array(try e.field(proof, "hashes"));
    try e.require(path.len <= 64);
    for (path) |sibling_encoded| {
        const sibling = try e.decode(a, try e.string(sibling_encoded));
        try e.require(sibling.len == 32 and last != 0);
        const left = index & 1 == 1 or index == last;
        hash = e.hash(try std.mem.concat(a, u8, if (left) &.{ &.{1}, sibling, &hash } else &.{ &.{1}, &hash, sibling }));
        if (left) while (index & 1 == 0 and index != 0) {
            index >>= 1;
            last >>= 1;
        };
        index >>= 1;
        last >>= 1;
    }
    try e.require(last == 0 and index == 0 and e.equal(&hash, try e.decode(a, try e.text(proof, "rootHash"))));
    const checkpoint = try e.text(try e.field(proof, "checkpoint"), "envelope");
    const boundary = std.mem.indexOf(u8, checkpoint, "\n\n") orelse return error.InvalidCheckpoint;
    const message = checkpoint[0 .. boundary + 1];
    var lines = std.mem.splitScalar(u8, message, '\n');
    const origin = lines.next() orelse return error.InvalidCheckpoint;
    try e.require(std.mem.startsWith(u8, origin, "rekor.sigstore.dev - "));
    try e.require(try std.fmt.parseInt(u64, lines.next() orelse return error.InvalidCheckpoint, 10) == size);
    try e.require(e.equal(try e.decode(a, lines.next() orelse return error.InvalidCheckpoint), &hash));
    try e.require(e.equal(lines.next() orelse return error.InvalidCheckpoint, "") and lines.next() == null);
    var notes = std.mem.splitScalar(u8, checkpoint[boundary + 2 ..], '\n');
    while (notes.next()) |line| {
        const prefix = "— rekor.sigstore.dev ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const sig = try e.decode(a, line[prefix.len..]);
        if (sig.len <= 4 or !e.equal(sig[0..4], id[0..4])) continue;
        key.verify(sig[4..], message) catch continue;
        return;
    }
    return error.InvalidCheckpointSignature;
}

pub fn sct(a: std.mem.Allocator, root: Value, leaf: certs.Certificate, issuer: certs.Certificate, now: u64) !void {
    const serialized = (try e.Der.one(try leaf.extension(certs.sct_oid), 4)).data;
    try e.require(serialized.len >= 4);
    try e.require(std.mem.readInt(u16, serialized[0..2], .big) == serialized.len - 2 and std.mem.readInt(u16, serialized[2..4], .big) == serialized.len - 4);
    const data = serialized[4..];
    try e.require(data.len >= 47 and data[0] == 0);
    const milliseconds = std.mem.readInt(u64, data[33..41], .big);
    const time = milliseconds / 1000;
    try e.require(time <= now and time >= leaf.before and time <= leaf.after);
    const key = try logKey(a, root, "ctlogs", data[1..33], time);
    const extension_len = std.mem.readInt(u16, data[41..43], .big);
    try e.require(extension_len <= data.len - 47);
    const sig_offset = 43 + @as(usize, extension_len);
    try e.require(data[sig_offset] == 4 and data[sig_offset + 1] == 3); // SHA256/ECDSA
    try e.require(std.mem.readInt(u16, data[sig_offset + 2 ..][0..2], .big) == data.len - sig_offset - 4);
    // RFC 6962 precertificate: remove SCT extension, preserving all other signed fields.
    var extensions: std.Io.Writer.Allocating = .init(a);
    var rest = leaf.extensions.data;
    while (rest.len > 0) {
        const ext = try certs.Extension.take(&rest);
        if (!e.equal(ext.oid, certs.sct_oid)) try extensions.writer.writeAll(ext.raw);
    }
    const wrapper = try e.wrap(a, 0xa3, try e.wrap(a, 0x30, extensions.written()));
    const precert = try e.wrap(a, 0x30, try std.mem.concat(a, u8, &.{ leaf.tbs.data[0 .. leaf.tbs.data.len - leaf.extensions_wrapper.raw.len], wrapper }));
    var len: [3]u8 = undefined;
    std.mem.writeInt(u24, &len, @intCast(precert.len), .big);
    const signed = try std.mem.concat(a, u8, &.{ &.{ 0, 0 }, data[33..41], &.{ 0, 1 }, &e.hash(issuer.spki), &len, precert, data[41..sig_offset] });
    try key.verify(data[sig_offset + 4 ..], signed);
}
