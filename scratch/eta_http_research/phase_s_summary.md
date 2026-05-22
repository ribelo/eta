# Phase H-S Summary

Question: can the current OCaml/Eio/OxCaml substrates carry eta-http before
Phase H-D?

Status: PASS-WITH-CAVEAT for continuing design, FAIL for the exact pinned
production TLS substrate.

## Verdicts

| Hypothesis | Verdict | Artifact | Constraint |
| --- | --- | --- | --- |
| H-S0 HTTP/1.1 substrate | PASS-WITH-CAVEAT / partial | h_s0_cohttp_eio_h1 | cohttp-eio basics pass, but eta-http must own h1 pooling, trailers, and HEAD enforcement or pivot. |
| H-S1 ocaml-h2 sans-IO over Eio | PASS-WITH-CAVEAT | h_s1_ocaml_h2_eio | h2 works over Eio/TLS, but adapter must own graceful GOAWAY admission/cutoff semantics. |
| H-S2 tls-eio ALPN | PASS-WITH-CAVEAT | h_s2_tls_eio_alpn | ALPN works on the older TLS branch; latest TLS branch remains blocked under OxCaml. |
| H-S3 production-grade client TLS | FAIL | h_s3_tls_grade | pinned tls.0.17.5 accepts DH1024, has published advisories, and has no live revocation by default. |
| H-S4a timeout cancellation safety | PASS-WITH-CAVEAT | h_s4a_cancellation_safety | local TCP/TLS/read/write timeout cleanup passes; fiber measurement is fixture-managed. |

## H-D Gate

H-D may proceed only as a constrained design phase. It must not assume the exact
pinned ocaml-tls stack is production-grade.

Required constraints for H-D:

- Treat H-S3 as a blocking TLS substrate decision. Use tls >= 2.1.0 only after
  it compiles and passes H-S3 under OxCaml, or pick another TLS substrate.
- Preserve ADR 0001: eta-http must not claim live revocation checking unless a
  caller-owned revocation policy/API is deliberately designed and tested.
- Own HTTP/1.1 pooling, trailer handling, and HEAD enforcement if cohttp-eio
  remains the h1 substrate.
- Own h2 GOAWAY admission/cutoff behavior if ocaml-h2 remains the h2 substrate.
- Keep Eta.timeout taxonomy: caller deadline exceeded is Cause.Fail Timeout;
  cancellation of losers/children is Cause.Interrupt.

## Verification Notes

Focused lab commands and outputs are recorded in each hypothesis results.md and
in journal.md. The shipped Eta package gate passes:

    nix develop .#oxcaml -c eta-oxcaml-test-shipped

Root dune build remains impractical while unrelated stale scratch directories
still reference old effet/ppx_effet APIs.
