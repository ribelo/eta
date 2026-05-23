# ADR 0002: TLS Substrate Pivot for eta-http v1

Status: Accepted

## Context

H-S3 failed for the unconstrained pinned TLS branch:

- tls/tls-eio 0.17.5 accepted dh1024.badssl.com under TLS 1.2.
- OSV reports OSEC-2026-06 / CVE-2026-45388 for tls < 2.1.0, affecting TLS
  1.3 client KeyUsage/ExtendedKeyUsage checks.
- The default CA authenticator has no live OCSP or CRL fetching.

Option 1, upgrading to tls/tls-eio 2.1.0, remains blocked in this OxCaml switch
because digestif 1.3.0 does not compile. The solver can select tls 2.1.0,
tls-eio 2.1.0, x509 1.0.6, and mirage-crypto 2.1.0, but digestif fails during
build.

## Decision

eta-http v1 may use the older OCaml TLS branch only under this explicit policy:

- TLS version range is exactly TLS 1.2.
- Cipher suites are restricted to ECDHE RSA/ECDSA AEAD suites.
- DHE_RSA suites are not offered.
- TLS 1.3 is not offered on this substrate.
- Revocation is caller-owned per ADR 0001. eta-http must not claim browser-like
  live revocation.

This is a constrained production client TLS claim, not an endorsement of the
unconstrained tls 0.17.5 defaults.

## Evidence

Artifacts:

- scratch/eta_http_research/h_s3_pivot/badssl_rerun.ml
- scratch/eta_http_research/h_s3_pivot/local_cert_rerun.ml
- scratch/eta_http_research/h_s3_pivot/revocation_fixtures.ml
- scratch/eta_http_research/h_s3_pivot/advisory_audit_rerun.md
- scratch/eta_http_research/h_s3_pivot/results.md

BadSSL rerun:

- expired, self-signed, untrusted-root, wrong-host, dh1024, and rc4-md5 reject;
- hsts.badssl.com accepts under TLS 1.2;
- dh1024 rejects by handshake failure because DHE_RSA suites are absent.

Local certificate rerun:

- SAN, wildcard, wildcard-too-deep rejection, multiple SAN, IP literal, IDNA
  A-label, SNI certificate selection, and TLS 1.2-only rows pass;
- TLS 1.3-only is rejected by policy.

Revocation fixtures:

- without CRLs the local certificate accepts;
- with a caller-supplied CRL containing the leaf serial, TLS rejects the chain;
- caller-owned policy classifies revoked, stale, unavailable, and unknown.

## Verification

H-S3-Reach:

- scratch/eta_http_research/h_s3_reach/targets.md
- scratch/eta_http_research/h_s3_reach/probe.ml
- scratch/eta_http_research/h_s3_reach/results.md
- scratch/eta_http_research/h_s3_reach/verdict.md

Verdict: Option 2 stands with caveats. The corrected 13-target reachability
matrix accepted TLS 1.2 with the narrowed ECDHE-AEAD cipher policy across OTLP,
LLM-provider, Cloudflare-fronted, and AWS-fronted endpoint classes. No tested
target required TLS 1.3.

Caveats:

- Azure OpenAI exact data-plane coverage remains unproven because those hosts
  are tenant/resource-specific.
- The OpenTelemetry demo collector is compose-internal; the probe covers the
  public reference host, not a hosted demo collector.

H-S3-Enforce:

- scratch/eta_http_research/h_s3_enforce/default_config_builder.ml
- scratch/eta_http_research/h_s3_enforce/invariants.ml
- scratch/eta_http_research/h_s3_enforce/negative_tls13_override.ml
- scratch/eta_http_research/h_s3_enforce/negative_dhe_cipher_override.ml
- scratch/eta_http_research/h_s3_enforce/results.md

Verdict: PASS. The lab now has a single internal construction chokepoint whose
documented paths directly inspect as TLS 1.2 only with exactly the six
ECDHE-AEAD ciphers. Attempts to pass TLS 1.3 or DHE_RSA overrides through the
helper fail to compile because the helper exposes no version or cipher labels.

Residual risk: the chokepoint is scratch-internal until eta-http v1 lands. The
implementation epic must move this helper shape and invariant fixtures with the
real eta-http TLS API.

## Consequences

eta-http v1 documentation and implementation must surface this constraint:
TLS 1.3 is unavailable on the older tls 0.17.5 substrate. A future move to
tls/tls-eio 2.1.0 or another substrate can supersede this ADR.

The implementation epic must not use Tls.Config.Ciphers.http2 directly for
client TLS on this branch. It must use the narrowed ECDHE AEAD list recorded in
the H-S3 pivot lab.

## Alternatives

Upgrade to tls/tls-eio 2.1.0:

- Deferred. This is the cleaner long-term path, but digestif 1.3.0 blocks it
  under the current OxCaml switch.

Select a different TLS substrate:

- Deferred. Option 2 now satisfies the v1 client TLS claim with explicit
  constraints. A libcurl/ocurl or vendored TLS fork remains available if TLS
  1.3 becomes a v1 requirement.

Ignore the advisories and default cipher list:

- Rejected. The BadSSL and OSV evidence directly contradict a production-grade
  claim for the unconstrained branch.
