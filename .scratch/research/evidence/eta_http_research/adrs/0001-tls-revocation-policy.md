# ADR 0001: TLS Revocation Policy for eta-http Substrate Research

Status: Proposed for eta-http substrate decision

## Context

H-S3 evaluates whether the current OCaml/Eio/OxCaml TLS substrate is viable for
production eta-http client TLS.

The pinned stack is:

- tls.0.17.5
- tls-eio.0.17.5
- x509.0.16.5
- ca-certs.0.2.3
- mirage-crypto.0.11.3
- mirage-crypto-rng.0.11.3
- mirage-crypto-rng-eio.0.11.3

Source inspection shows:

- X509.Authenticator.chain_of_trust can check revocation when ?crls is supplied.
- Ca_certs.authenticator () defaults to no CRL list.
- X509_eio.authenticator can load CRLs from a caller-provided path.
- No default live OCSP or CRL network fetch path is present in the client
  authenticator path.

Eta's boundary remains unchanged: applications own state and policy; Eta owns
effect description and interpretation. Hidden network fetches inside the
substrate would introduce application-visible I/O, caching, failure policy, and
privacy behavior.

## Decision

eta-http must not claim browser-equivalent revocation checking on this
substrate.

For this research phase, the revocation policy is:

- Default client TLS validation uses CA chain, time, hostname/IP, and local
  certificate checks supplied by the TLS stack.
- Default client TLS validation does not perform live OCSP or CRL fetching.
- If eta-http proceeds with this stack, its public API must make revocation
  policy explicit before production release: either accept caller-provided CRLs
  or expose a policy hook owned by the application.
- A hard-fail revocation mode requires explicit application opt-in and test
  fixtures for unavailable, stale, revoked, and unknown status cases.

## Consequences

This ADR weakens the viable claim for H-S3. The current substrate can validate
chains and names, but it does not provide full production browser-style
revocation behavior by default.

The policy keeps Eta's ownership boundary intact. Applications that need
revocation semantics must own the cache, update schedule, trust anchors, failure
mode, and privacy tradeoff until eta-http has a deliberately designed API.

## Alternatives

Use implicit live OCSP/CRL fetching inside eta-http:

- Rejected for this phase. It adds hidden I/O and state policy before H-D has a
  proven design.

Ignore revocation entirely:

- Rejected as a claim. The default stack effectively has no live revocation, but
  eta-http documentation and APIs must say that explicitly.

Require hard-fail revocation for every client request:

- Deferred. It needs fresh fixtures and an application-owned cache/policy model
  to avoid turning transient responder failures into global client outages.

## Verification

Evidence is recorded in:

- .scratch/research/evidence/eta_http_research/h_s3_tls_grade/security_audit.md
- .scratch/research/evidence/eta_http_research/h_s3_tls_grade/results.md
- journal.md entry V-Http-S3-PartC-Audit-Revocation
