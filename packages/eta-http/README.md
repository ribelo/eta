# eta-http

Clean-room HTTP client package for Eta.

eta-http v1 will provide a production-shape HTTP/1.1 and HTTP/2 client for
Eta applications. The package owns client lifecycle, typed errors, pooling,
streaming request and response bodies, retries, and observability. It delegates
TLS to `tls`/`tls-eio` and HTTP/2 frame + HPACK handling to `h2`.

## Status

This package is in S1 from
[`scratch/eta_http_v1/OBJECTIVE.md`](../../scratch/eta_http_v1/OBJECTIVE.md).
Current implemented surface:

- typed error taxonomy, redaction, and JSON-style projection;
- request/response model and byte body stream;
- ADR 0002 TLS 1.2 + ECDHE-AEAD config chokepoint;
- RFC 3986 client-subset URL parser for absolute `http`/`https` URLs;
- HTTP/1.1 request serialization to origin-form with `Host`, keep-alive, and
  fixed-body `Content-Length`;
- zero-allocation h1 byte-buffer writer core, with direct flow writing on the
  transport path;
- HTTP/1.x response parser for status line, headers, fixed bodies, typed
  parser errors, a zero-allocation raw parser core, and a 32 KiB h1 client
  read loop;
- DNS target construction and `Eio.Net.getaddrinfo_stream` resolution with
  typed `Dns_error` failures;
- TCP connect and TLS wrapping through the ADR 0002 chokepoint;
- public `Eta_http.Client.make_h1` and `Eta_http.request` path for HTTP/1.1;
- origin-scoped h1 connection pooling through `Eta.Pool` with idle-entry
  health rejection;
- real loopback stale-idle h1 peer rejection through the default pool health
  check;
- h1 pooled response bodies hold the pool checkout until body EOF or discard;
- TLS compile-fail fixtures for forbidden `~version` and `~ciphers` overrides;
- live audit catalogs.

S1 live OpenAI 401 smoke passes through
`scratch/eta_http_v1/probes/openai_401.exe`. S1 13-endpoint reach passes
through `scratch/eta_http_v1/probes/reach_13.exe`.

Still pending in S1: R6 cancellation/real-peer leak closure.

## Public API TOC

| Module | Purpose |
| --- | --- |
| `Eta_http.Client` | Top-level client API. |
| `Eta_http.Request` | Request model. |
| `Eta_http.Response` | Response model. |
| `Eta_http.Error` | Typed eta-http failures and projections. |
| `Eta_http.Core` | URL, method, version, header, status, and span helpers. |
| `Eta_http.Body` | Request and response body surfaces. |
| `Eta_http.Tls` | TLS policy chokepoint. |
| `Eta_http.Transport` | DNS, TCP, TLS, ALPN, and protocol dispatch. |
| `Eta_http.H1` | HTTP/1.1 parser, writer, and client loop. |
| `Eta_http.H2` | HTTP/2 frame adapter, multiplexer, writer, and admission state. |

## Constraints

- Source is written clean-room against RFCs, Eta primitives, and the v1
  objective. Reference libraries are design input only.
- Dependencies stay inside the allow-list in the objective. Adding another
  dependency is a planner decision.
- `cstruct` is a direct dependency because `Eio.Flow.single_read` exposes
  flow reads through `Cstruct.t`; it is already in the Eta dependency closure
  through `eta-stream`/Eio.
- `digestif` is not a direct dependency on the ADR 0002 TLS branch. The newer
  TLS branch pulls it in, but `digestif` 1.3.0 is documented as failing under
  the current OxCaml switch.
- Applications own state. eta-http owns effect description, client protocol
  interpretation, and resource lifecycle.
- The audit catalogs are the truth-of-record for dependency use and Eta
  primitive escapes.

## Audit Catalogs

Run:

```sh
bash packages/eta-http/audit/run.sh
```

Catalogs:

- [`audit/dep_usage.md`](audit/dep_usage.md)
- [`audit/eta_escapes.md`](audit/eta_escapes.md)

## Development

Current local smoke:

```sh
nix develop -c dune build packages/eta-http
nix develop -c dune runtest packages/eta-http --force
bash packages/eta-http/audit/run.sh
nix develop -c dune exec scratch/eta_http_v1/probes/parser_alloc.exe
nix develop -c dune exec scratch/eta_http_v1/probes/stale_idle.exe
```

Live S1 h1 smoke:

```sh
nix develop -c dune exec scratch/eta_http_v1/probes/openai_401.exe
nix develop -c dune exec scratch/eta_http_v1/probes/reach_13.exe
```

Full shipped Eta gate:

```sh
nix develop -c eta-oxcaml-test-shipped
```

## Limits

The package exposes a working S1 h1 request path with origin-scoped pooling.
The S1 response body path is still eager, but pooled h1 connections are not
returned to the pool until the body reaches EOF or is discarded. Chunked
transfer and gzip land in S3; HTTP/2 ALPN dispatch lands in S2.
