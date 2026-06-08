# H-S3-Reach

Phase 1 falsifier for ADR 0002.

Hypothesis: every endpoint class eta-http v1 is intended to reach accepts a TLS
1.2 client hello using the constrained Option 2 policy:

- TLS version range exactly TLS 1.2;
- ECDHE RSA/ECDSA AEAD cipher suites only;
- no DHE_RSA suites;
- CA validation through the platform CA bundle;
- no live revocation fetching.

Run:

    nix develop -c dune exec scratch/eta_http_research/h_s3_reach/probe.exe

The probe offers eta-http's normal ALPN set, h2 then http/1.1, and sends no
application data. The handshake outcome is the evidence.

Disproof: any intended endpoint class rejects the handshake with a TLS-layer
failure attributable to requiring TLS 1.3 or refusing the narrowed TLS 1.2
cipher policy.
