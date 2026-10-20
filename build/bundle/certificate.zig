//! Fulcio X.509 policy and ECDSA signatures using Zig's standard crypto primitives.
const std = @import("std");
const e = @import("encoding.zig");
const Der = e.Der;
const p256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const p384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;
const ec_algorithm = "\x06\x07\x2a\x86\x48\xce\x3d\x02\x01";
const p256_oid = "\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07";
const p384_oid = "\x06\x05\x2b\x81\x04\x00\x22";
const sha256_algo = "\x30\x0a\x06\x08\x2a\x86\x48\xce\x3d\x04\x03\x02";
const sha384_algo = "\x30\x0a\x06\x08\x2a\x86\x48\xce\x3d\x04\x03\x03";
pub const sct_oid = "\x2b\x06\x01\x04\x01\xd6\x79\x02\x04\x02";
pub const Key = struct {
    bytes: []const u8,
    curve: enum { p256, p384 },
    pub fn parse(spki: []const u8) !Key {
        var seq = (try Der.one(spki, 0x30)).data;
        const algo = try Der.take(&seq, 0x30);
        const bit = try Der.take(&seq, 3);
        if (seq.len != 0 or bit.data.len <= 1 or bit.data[0] != 0) return error.InvalidAttestation;
        if (!std.mem.startsWith(u8, algo.data, ec_algorithm)) return error.InvalidAttestation;
        const curve = algo.data[ec_algorithm.len..];
        if (std.mem.eql(u8, curve, p256_oid) and bit.data.len == 66) return .{ .bytes = bit.data[1..], .curve = .p256 };
        if (std.mem.eql(u8, curve, p384_oid) and bit.data.len == 98) return .{ .bytes = bit.data[1..], .curve = .p384 };
        return error.UnsupportedSignatureAlgorithm;
    }
    pub fn verify(key: Key, signature: []const u8, message: []const u8) !void {
        switch (key.curve) {
            .p256 => try (try p256.Signature.fromDer(signature)).verify(message, try p256.PublicKey.fromSec1(key.bytes)),
            .p384 => try (try p384.Signature.fromDer(signature)).verify(message, try p384.PublicKey.fromSec1(key.bytes)),
        }
    }
};
pub const Certificate = struct {
    raw: []const u8,
    tbs: Der,
    issuer: []const u8,
    subject: []const u8,
    spki: []const u8,
    algorithm: []const u8,
    signature: []const u8,
    before: u64,
    after: u64,
    extensions: Der,
    extensions_wrapper: Der,
    pub fn parse(raw: []const u8) !Certificate {
        var top = (try Der.one(raw, 0x30)).data;
        const tbs = try Der.take(&top, 0x30);
        const algorithm = try Der.take(&top, 0x30);
        const signature = try Der.take(&top, 3);
        if (top.len != 0 or signature.data.len <= 1 or signature.data[0] != 0) return error.InvalidAttestation;
        var body = tbs.data;
        if (!std.mem.eql(u8, (try Der.take(&body, 0xa0)).data, "\x02\x01\x02")) return error.InvalidAttestation;
        const serial = try Der.take(&body, 2);
        if (serial.data.len == 0 or serial.data.len > 20 or serial.data[0] & 128 != 0) return error.InvalidAttestation;
        const inner_algorithm = try Der.take(&body, 0x30);
        if (!std.mem.eql(u8, inner_algorithm.raw, algorithm.raw)) return error.InvalidAttestation;
        if (!std.mem.eql(u8, algorithm.raw, sha256_algo) and !std.mem.eql(u8, algorithm.raw, sha384_algo)) return error.InvalidAttestation;
        const issuer = try Der.take(&body, 0x30);
        var validity = (try Der.take(&body, 0x30)).data;
        const before = try Der.read(validity);
        validity = validity[before.raw.len..];
        const after = try Der.read(validity);
        if (after.raw.len != validity.len) return error.InvalidAttestation;
        const subject = try Der.take(&body, 0x30);
        const spki = try Der.take(&body, 0x30);
        _ = try Key.parse(spki.raw);
        const wrapper = try Der.take(&body, 0xa3);
        if (body.len != 0) return error.InvalidAttestation;
        return .{ .raw = raw, .tbs = tbs, .issuer = issuer.raw, .subject = subject.raw, .spki = spki.raw, .algorithm = algorithm.raw, .signature = signature.data[1..], .before = try e.certTime(before), .after = try e.certTime(after), .extensions = try Der.one(wrapper.data, 0x30), .extensions_wrapper = wrapper };
    }
    pub fn verify(cert: Certificate, issuer: Certificate, time: u64) !void {
        if (!std.mem.eql(u8, cert.issuer, issuer.subject) or time < cert.before or time > cert.after) return error.InvalidAttestation;
        const key = try Key.parse(issuer.spki);
        if ((key.curve == .p256 and !std.mem.eql(u8, cert.algorithm, sha256_algo)) or (key.curve == .p384 and !std.mem.eql(u8, cert.algorithm, sha384_algo))) return error.InvalidAttestation;
        try key.verify(cert.signature, cert.tbs.raw);
    }
    pub fn extension(cert: Certificate, wanted: []const u8) ![]const u8 {
        var rest = cert.extensions.data;
        var found: ?[]const u8 = null;
        while (rest.len > 0) {
            const ext = try Extension.take(&rest);
            if (std.mem.eql(u8, ext.oid, wanted)) {
                if (found != null) return error.DuplicateExtension;
                found = ext.data;
            }
        }
        return found orelse error.MissingCertificateExtension;
    }
    pub fn claim(cert: Certificate, id: u8, expected: []const u8) !void {
        const oid = "\x2b\x06\x01\x04\x01\x83\xbf\x30\x01" ++ [1]u8{id};
        const text = try Der.one(try cert.extension(oid), 0x0c);
        if (!std.mem.eql(u8, text.data, expected)) return error.CertificateIdentityMismatch;
    }
    pub fn leafUsage(cert: Certificate, a: std.mem.Allocator) !void {
        // Pin the supported Fulcio leaf profile. Unknown critical constraints fail closed.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(a);
        var rest = cert.extensions.data;
        while (rest.len > 0) {
            const ext = try Extension.take(&rest);
            const result = try seen.getOrPut(a, ext.oid);
            if (result.found_existing) return error.DuplicateExtension;
            if (ext.critical and !std.mem.eql(u8, ext.oid, "\x55\x1d\x0f") and !std.mem.eql(u8, ext.oid, "\x55\x1d\x11") and !std.mem.eql(u8, ext.oid, "\x55\x1d\x13") and !std.mem.eql(u8, ext.oid, "\x55\x1d\x25")) return error.UnsupportedCriticalExtension;
        }
        if (!std.mem.eql(u8, try cert.extension("\x55\x1d\x0f"), "\x03\x02\x07\x80")) return error.InvalidAttestation;
        if (!std.mem.eql(u8, try cert.extension("\x55\x1d\x25"), "\x30\x0a\x06\x08\x2b\x06\x01\x05\x05\x07\x03\x03")) return error.InvalidAttestation;
        if (cert.extension("\x55\x1d\x13")) |constraints| {
            if (!std.mem.eql(u8, constraints, "\x30\x00") and !std.mem.eql(u8, constraints, "\x30\x03\x01\x01\x00")) return error.InvalidAttestation;
        } else |err| if (err != error.MissingCertificateExtension) return err;
    }
};
pub const Extension = struct {
    raw: []const u8,
    oid: []const u8,
    data: []const u8,
    critical: bool,
    pub fn take(rest: *[]const u8) !Extension {
        const ext = try Der.take(rest, 0x30);
        var body = ext.data;
        const oid = try Der.take(&body, 6);
        var critical = false;
        if (body.len > 0 and body[0] == 1) {
            const flag = try Der.take(&body, 1);
            if (!std.mem.eql(u8, flag.data, "\xff")) return error.InvalidAttestation;
            critical = true;
        }
        const data = try Der.take(&body, 4);
        if (body.len != 0) return error.InvalidAttestation;
        return .{ .raw = ext.raw, .oid = oid.data, .data = data.data, .critical = critical };
    }
};
