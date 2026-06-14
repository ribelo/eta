# Dependency Usage Audit

Run: `bash lib/http/audit/run.sh`
Last updated: 2026-06-10T10:56:18Z
Current sites: 0

## Scope

This audit checks the shared `eta_http` package for backend ownership leaks.
The shared package may expose protocol substrate shapes where they are part of
the shared protocol helpers, but it must not depend on Eio, `eta_eio`, or an
HTTP backend adapter.

Allowed shared protocol dependencies include:

- `cstruct`, `bigstringaf`, `faraday`, and `eta_http_h2` for HTTP/2 and
  serializer substrate values.
- `angstrom`, `decompress`, `domain-name`, `ipaddr`, `base64`, `yojson`,
  `unix`, and the local OpenSSL stubs for backend-neutral parsing, compression,
  policy, diagnostics, and protocol helpers.

Backend transport dependencies belong in adapter packages:

- `eta_http_eio` owns Eio DNS, TCP, TLS, ALPN dispatch, HTTP/1.1 pooling,
  HTTP/2 connection ownership, and WebSocket client I/O.

## Search

```sh
bash lib/http/audit/run.sh
```

The script scans shared OCaml sources for raw `Eio.*` or `Eta_eio` use and
the shared `lib/http/dune` stanza for direct Eio library dependencies.

## Classification

No backend dependency sites are currently allowed in shared `eta_http`.

If this audit reports a site, either move that code into a backend adapter or
change the shared contract so the backend supplies the capability through
`Eta.Runtime_contract.service`.
