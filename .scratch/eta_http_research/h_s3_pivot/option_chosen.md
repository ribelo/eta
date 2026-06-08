# H-S3 Pivot Option

Status: accepted.

Option 1 remains the preferred clean pivot because tls 2.1.0 fixes the known
client TLS 1.3 KeyUsage advisory. It is not currently reachable in this OxCaml
switch because digestif 1.3.0 fails to compile.

The chosen pivot is Option 2: narrow the older branch until it avoids the
known failure modes that made H-S3 fail:

- TLS version range fixed to TLS 1.2 only, avoiding the tls 0.17.5 TLS 1.3
  client KeyUsage advisory path.
- Cipher list restricted to ECDHE AEAD ciphers.
- DHE_RSA ciphers removed so dh1024.badssl.com has no acceptable weak-DH path.
- Revocation remains caller-owned per ADR 0001; fixtures cover revoked, stale,
  unavailable, and unknown outcomes.

This is a constrained PASS after the BadSSL rerun, local certificate rerun,
advisory audit, revocation fixtures, ADR 0002, and journal entry. The
eta-oxcaml-test-shipped gate is recorded in results once run.
