# Dependency Usage Audit

Run: `bash lib/http/audit/run.sh`
Last updated: 2026-06-28T09:12:16Z
Current sites: 0

## Scope

This audit checks the shared `eta_http` package for backend ownership leaks.
The shared package may expose protocol substrate shapes where they are part of
the shared protocol helpers, but it must not depend on Eio, `eta_eio`, or an
HTTP backend adapter.

Allowed shared dependencies include:

- `decompress`, `domain-name`, `ipaddr`, `bigstringaf`, and `yojson` for
  backend-neutral body transducers, URL/host parsing, byte buffers, diagnostics,
  and projections.

Backend transport dependencies belong in adapter packages:

- `eta_http_eio` owns Eio DNS, TCP, TLS, ALPN dispatch, HTTP/1.1 pooling,
  HTTP/2 connection ownership, and WebSocket client I/O.
- `eta_http_js` owns js_of_ocaml Fetch integration.
- `eta_http_h1`, `eta_http_h2`, `eta_http_ws`, and `eta_http_tls_openssl` own
  concrete protocol/TLS/WebSocket substrate.

## Search

```sh
bash lib/http/audit/run.sh
```

The script scans shared OCaml sources and the shared `lib/http/dune` stanza for
raw Eio, JS, OpenSSL, concrete protocol helper, or backend adapter dependencies.

## Classification

No backend dependency sites are currently allowed in shared `eta_http`.

If this audit reports a site, either move that code into a backend adapter or
change the shared contract so the backend supplies the capability through
`Eta.Runtime_contract.service`.
