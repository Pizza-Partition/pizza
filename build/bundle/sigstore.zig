//! Native, offline verifier for pizza-bundle's Sigstore v0.3 / DSSE / Rekor v1 profile.
//! Trust is embedded in the executable; certificates or keys in an artifact never become roots.
const std = @import("std");
const e = @import("encoding.zig");
const certs = @import("certificate.zig");
const transparency = @import("transparency.zig");
pub const Policy = struct { repository: []const u8, repository_id: []const u8, workflow: []const u8, tag: []const u8, commit: []const u8 };
const trusted_root = @embedFile("trust/sigstore-public-good.json");

pub fn verify(a: std.mem.Allocator, bytes: []const u8, policy: Policy, assets: []const [2][]const u8, now: u64) !void {
    // GitHub distributes JSONL. Require exactly one attestation for this fixed release profile.
    const bundle = try e.json(a, bytes);
    try e.require(e.equal(try e.text(bundle, "mediaType"), "application/vnd.dev.sigstore.bundle.v0.3+json"));
    const root = try e.json(a, trusted_root);
    const material = try e.field(bundle, "verificationMaterial");
    const der = try e.decode(a, try e.text(try e.field(material, "certificate"), "rawBytes"));
    const leaf = try certs.Certificate.parse(der);
    try leaf.leafUsage(a);
    const envelope = try e.field(bundle, "dsseEnvelope");
    const kind = try e.text(envelope, "payloadType");
    try e.require(e.equal(kind, "application/vnd.in-toto+json"));
    const payload = try e.decode(a, try e.text(envelope, "payload"));
    const signatures = try e.array(try e.field(envelope, "signatures"));
    try e.require(signatures.len == 1);
    const signature = try e.decode(a, try e.text(signatures[0], "sig"));
    const key = try certs.Key.parse(leaf.spki);
    try e.require(key.curve == .p256);
    try key.verify(signature, try a.print("DSSEv1 {d} {s} {d} {s}", .{ kind.len, kind, payload.len, payload }));
    const entries = try e.array(try e.field(material, "tlogEntries"));
    try e.require(entries.len == 1);
    const time = try transparency.rekor(a, root, entries[0], payload, signature, der, now);
    const issuer = try verifyChain(a, root, leaf, time);
    try transparency.sct(a, root, leaf, issuer, now);
    try identity(a, leaf, policy);
    try statement(a, try e.json(a, payload), policy, assets);
}

fn verifyChain(a: std.mem.Allocator, root: e.Value, leaf: certs.Certificate, time: u64) !certs.Certificate {
    for (try e.array(try e.field(root, "certificateAuthorities"))) |authority| {
        const certificates = try e.array(try e.field(try e.field(authority, "certChain"), "certificates"));
        if (certificates.len != 2) continue; // Current pinned public Fulcio issuer + root.
        const issuer = try certs.Certificate.parse(try e.decode(a, try e.text(certificates[0], "rawBytes")));
        if (!e.equal(leaf.issuer, issuer.subject)) continue;
        try e.validAt(try e.field(authority, "validFor"), time);
        const anchor = try certs.Certificate.parse(try e.decode(a, try e.text(certificates[1], "rawBytes")));
        try anchor.verify(anchor, time);
        try issuer.verify(anchor, time);
        try leaf.verify(issuer, time);
        return issuer;
    }
    return error.UntrustedCertificateIssuer;
}

fn identity(a: std.mem.Allocator, leaf: certs.Certificate, policy: Policy) !void {
    const repository = try a.print("https://github.com/{s}", .{policy.repository});
    const ref = try a.print("refs/tags/{s}", .{policy.tag});
    const workflow = try a.print("https://github.com/{s}@{s}", .{ policy.workflow, ref });
    const san = try e.Der.one(try leaf.extension("\x55\x1d\x11"), 0x30);
    try e.require(e.equal((try e.Der.one(san.data, 0x86)).data, workflow));
    try leaf.claim(8, "https://token.actions.githubusercontent.com");
    try leaf.claim(9, workflow);
    try leaf.claim(10, policy.commit);
    try leaf.claim(11, "github-hosted");
    try leaf.claim(12, repository);
    try leaf.claim(13, policy.commit);
    try leaf.claim(14, ref);
    try leaf.claim(15, policy.repository_id);
    try leaf.claim(18, workflow);
    try leaf.claim(19, policy.commit);
}

fn statement(a: std.mem.Allocator, value: e.Value, policy: Policy, assets: []const [2][]const u8) !void {
    try e.require(e.equal(try e.text(value, "_type"), "https://in-toto.io/Statement/v1") and e.equal(try e.text(value, "predicateType"), "https://slsa.dev/provenance/v1"));
    const subjects = try e.array(try e.field(value, "subject"));
    for (assets) |asset| {
        var count: usize = 0;
        for (subjects) |subject| if (e.equal(try e.text(subject, "name"), asset[0])) {
            try e.require(e.equal(try e.text(try e.field(subject, "digest"), "sha256"), asset[1]));
            count += 1;
        };
        if (count != 1) return error.AttestationSubjectMismatch;
    }
    const predicate = try e.field(value, "predicate");
    const definition = try e.field(predicate, "buildDefinition");
    try e.require(e.equal(try e.text(definition, "buildType"), "https://actions.github.io/buildtypes/workflow/v1"));
    const workflow = try e.field(try e.field(definition, "externalParameters"), "workflow");
    try e.require(e.equal(try e.text(workflow, "repository"), try a.print("https://github.com/{s}", .{policy.repository})) and e.equal(try e.text(workflow, "ref"), try a.print("refs/tags/{s}", .{policy.tag})));
    const slash = std.mem.indexOf(u8, policy.workflow, "/.github/") orelse return error.InvalidAttestation;
    try e.require(e.equal(try e.text(workflow, "path"), policy.workflow[slash + 1 ..]));
    const builder = try e.field(try e.field(predicate, "runDetails"), "builder");
    try e.require(e.equal(try e.text(builder, "id"), try a.print("https://github.com/{s}@refs/tags/{s}", .{ policy.workflow, policy.tag })));
}
