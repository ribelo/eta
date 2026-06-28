# ADR 0004 — HTTP/2 ownership boundary

Status: Draft accepted for eta-http v1 S2  
Date: 2026-05-23

## Context

Eta-http v1 needs an HTTP/2 client without owning a full HPACK/frame parser.
The implementation uses `ocaml-h2` as the h2 Sans-IO substrate and wraps it in
Eta-owned lifecycle, admission, and audit rules.

S2 evidence:

- R7 API-shape probe passes against real `H2.Client_connection` and
  `H2.Server_connection`.
- R8 push-disabled/PRIORITY probe passes.
- H-D1 stress rows pass on real `ocaml-h2`: 100 concurrent GETs, upload
  flow-control resume, server reset admission/release, client cancellation
  release, and blocked-writer teardown.
- Public auto-ALPN dispatch passes Honeycomb h2 smoke and 13-endpoint reach.
- GOAWAY post-close admission cutoff passes after `ocaml-h2` marks the client
  closed following writer drain.

## Decision

Eta-http uses `ocaml-h2` for the byte-level HTTP/2 substrate and owns the
client lifecycle around it.

`ocaml-h2` owns:

- HTTP/2 frame parsing and serialization.
- HPACK encode/decode and header-block representation.
- HTTP/2 stream callbacks and body reader/writer primitives.
- Flow-control scheduling.
- Connection close state after protocol events such as GOAWAY.

Eta-http owns:

- Public request/response API and typed eta-http errors.
- ALPN route choice between h1 and h2.
- h2 admission policy over eta-http stream permits.
- Response-body release semantics and h2 body-reader close on cancellation.
- The supervised h2 read/write owner loop over Eio flows.
- Dependency/escape audit visibility.
- Security policy defaults and byte-envelope gates once S4 lands.

## Consequences

The S2 h2 client does not fork or reimplement HPACK/frame parsing. This keeps
the dependency boundary small and testable while preserving Eta's concurrency
discipline.

`ocaml-h2` does not expose received GOAWAY `last_stream_id` in the current
integration shape. Eta-http therefore treats the h2 client closed state after
GOAWAY writer drain as the S2 admission cutoff. Selective retry/admission by
`last_stream_id` is not claimed.

The h2 body surface is eager in S2. S3 owns streaming response exposure,
chunked h1 bodies, gzip, and retransmission classification.

H-Q2/H-Q5 byte-level security work remains S4. S2 proves the real h2
integration and records the boundary; S4 adds the malicious-server envelope
where `ocaml-h2` exposes or requires adapter hooks.

## Verification

```text
nix develop -c dune runtest packages/eta-http --force
eta-http: 44 tests passed

nix develop -c dune exec .scratch/eta_http_v1/probes/honeycomb_h2.exe
eta_http_s2_honeycomb outcome=ok status=404 body_bytes=19 protocol=h2 policy=tls12_ecdhe_aead_only

nix develop -c dune exec .scratch/eta_http_v1/probes/reach_13.exe
eta_http_reach_summary verdict=PASS targets=13 failed=<none> protocol=auto_alpn policy=tls12_ecdhe_aead_only

bash packages/eta-http/audit/run.sh
Dependency sites: 223
Eta escape sites: 0
```
