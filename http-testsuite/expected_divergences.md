# Expected Divergences

This file documents response fields that are intentionally excluded from the
differential comparison between `eta-http` and `curl`.  The interop runner
subtracts these fields before deciding Pass / Divergent.

## Excluded headers (normalized out)

| Header | Reason |
|---|---|
| `date` | Server-generated timestamp; varies per request. |
| `server` | Server software banner; may differ if nginx/Caddy add version info. |
| `via` | Proxy/intermediary stamp; not deterministic. |
| `set-cookie` | Cookie values include nonces / timestamps. |
| `connection` | Framing-level header; h1 keep-alive semantics differ between clients. |
| `transfer-encoding` | Chunked vs Content-Length framing may differ per client. |

## Known client-specific request differences

* `curl` sends `Accept: */*` and `User-Agent: curl/...` by default.
  `eta-http` does not send these unless explicitly provided in the scenario.
  The interop runner passes identical `headers` to both clients, so any
  default divergence is documented here rather than subtracted.

* `curl` with `--http2` may send HTTP/1.1 upgrade headers on plain TCP.
  `eta-http` uses ALPN on TLS for h2 negotiation.  h2c is not supported by
  the public `eta-http` client, so plain-h2 cells are skipped or documented.

## Known reported divergences

These scenarios remain `DIVERGENT` in the report instead of failing the alias:

* `large_body_1m` against Caddy h2/TLS: Caddy's `{http.request.body}`
  responder returns 65,535 bytes for eta-http's h2 request body but 1 MiB for
  curl. The result is retained as a visible interop difference.

* `response_trailers` against nginx h2/TLS: curl records the response trailer
  field in its dumped headers, while eta-http exposes trailers through the
  response trailer effect instead of merging them into response headers.

## How divergence subtraction works

The differential pipeline produces a `normalized_result` for each client:

* `status` — numeric integer.
* `body_sha256` — SHA-256 of received bytes.
* `body_length` — byte count.
* `headers_normalized` — sorted by lower-case name, with the excluded headers
  above stripped and multi-value headers concatenated with `, `.

A scenario is `Pass` when both normalized triples are equal after the
subtraction above.  Any remaining difference is `Divergent` and both raw
results are written to `results/<run-id>/<scenario>/`.
