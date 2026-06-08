# H-S3 TLS Grade Probe

Question: is the exact TLS stack currently viable for production eta-http
client TLS?

Pinned working branch from H-S2:

- `tls-eio.0.17.5`
- `tls.0.17.5`
- `x509.0.16.5`
- `ca-certs.0.2.3`
- `mirage-crypto.0.11.3`
- `mirage-crypto-rng.0.11.3`
- `mirage-crypto-rng-eio.0.11.3`

This lab covers:

- Part A BadSSL behavior in badssl_grid.ml.
- Part B local certificate fixtures in local_cert_matrix.ml.
- Part C exact-version security audit in security_audit.md.
- Revocation policy in ../adrs/0001-tls-revocation-policy.md.

Current verdict: H-S3 FAIL for production-grade client TLS on this pinned
branch. Positive SAN/SNI/TLS-version mechanics do not offset the DH1024
acceptance, published tls.0.17.5 advisories, and default no-live-revocation
policy.
