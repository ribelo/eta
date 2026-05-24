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

## How divergence subtraction works

The differential pipeline produces a `normalized_result` for each client:

* `status` — numeric integer.
* `body_sha256` — SHA-256 of received bytes.
* `body_length` — byte count.
* `headers_normalized` — sorted by lower-case name, with the excluded headers
  above stripped and multi-value headers concatenated with `, `.
* `trailers_normalized` — h2/h1 response trailers, sorted with the same
  normalization as headers but compared separately from initial headers.

A scenario is `Pass` when both normalized values are equal after the
subtraction above.  Any remaining difference is `Divergent` and both raw
results are written to `results/<run-id>/<scenario>/`.
