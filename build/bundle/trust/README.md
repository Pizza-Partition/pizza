Sigstore public-good trust root, vendored from
[the official root-signing repository](https://github.com/sigstore/root-signing/blob/742eb2ab924b1967adeaca0c8d59358615b56a6f/targets/trusted_root.json)
at commit `742eb2ab924b1967adeaca0c8d59358615b56a6f` (Apache-2.0).

This snapshot is embedded at compilation. Updating it is an explicit code review;
no key, CA or trust root supplied alongside an artifact can override it. There is
no automatic TUF updater. The verifier accepts the release's Sigstore v0.3 DSSE,
ECDSA P-256/SHA-256 signing key, public Fulcio P-384/SHA-384 issuer chain, Rekor
v1 DSSE log entry with SET and inclusion proof/checkpoint, and RFC 6962 SCT.
Unsupported algorithms/formats fail closed and require a reviewed implementation
and trust-root update before adopting a different producer profile.

The verifier checks the signed publication time against certificate and trust-key
validity. It validates certificate key usage, code-signing EKU, critical
extensions, GitHub issuer/workflow/repository ID/tag/commit/hosted runner claims,
DSSE PAE and in-toto artifact digests. It does not audit upstream ELF contents.
The official Sigstore bundle specification and RFC 6962 describe the wire formats.
