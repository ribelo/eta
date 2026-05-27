# S1 h1 Request Loop Probe

## Question

Can eta-http perform a real HTTP/1.1 request over the pinned ADR 0002 TLS stack
without using `digestif` or an h1 dependency?

## Implementation

- `Http.Transport.Connect.connect_tcp` resolves and opens TCP through
  Eio.
- `Http.Transport.Connect.connect_tls` wraps the TCP flow with
  `tls-eio` using the ADR 0002 TLS 1.2 ECDHE-AEAD policy.
- `Http.H1.Client.request_on_flow` writes the clean-room h1 request and
  reads status, headers, and fixed-length response bodies.
- `Http.Client.make_h1` exposes the path through `Http.request` and
  creates origin-scoped `Eta.Pool` pools lazily.
- The S1 h1 path offers only `http/1.1` over ALPN. S2 owns h2 ALPN dispatch.

## Evidence

```sh
nix develop -c dune runtest lib/http --force
nix develop -c dune exec scratch/eta_http_v1/probes/openai_401.exe
nix develop -c dune exec scratch/eta_http_v1/probes/reach_13.exe
```

Observed:

```text
eta-http: 24 tests passed
eta_http_openai_401 outcome=ok status=401 body_bytes=151 content_length="151" transfer_encoding="<none>" protocol=h1
eta_http_s1_reach_summary verdict=PASS targets=13 failed=<none> protocol=h1 policy=tls12_ecdhe_aead_only
```

## Verdict

PARTIAL PASS.

The public h1 request path is real and uses the digestif-free TLS workaround.
This is not an S1 close: R6 cancellation/real-peer leak closure remains open.

## Limits

- Chunked transfer encoding is rejected with `Decode_error`; S3 owns chunked
  and gzip.
- Bodies are read eagerly for S1. S3 owns streaming response bodies.
- Even with eager S1 bodies, pooled h1 connections stay checked out until body
  EOF or explicit discard.
