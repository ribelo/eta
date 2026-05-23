# H-D-Errors: Structured eta-http Error Taxonomy

## Question

Can eta-http expose one structured error payload that covers Track A request
failures and the Track B malicious-peer outcomes without leaking secrets through
default projections?

## Scope

This is a scratch proof, not a published package. The candidate surface is a
single eta-http error payload carried as an ordinary Eta typed failure:

    val request : Client.t -> Request.t -> (Response.t, Error.t) Eta.Effect.t

The lab deliberately keeps the structure outside Eta.Cause: Cause.t remains the
generic typed-failure container, and eta-http owns the HTTP-specific payload.

## Proof Obligations

- Cover the requested variants: connect timeout, TLS handshake, certificate
  validation, connection closed, pool shutdown/acquire timeout, response header
  timeout, response body idle timeout, total request timeout, HTTP status,
  decode error, HPACK overflow, CONTINUATION flood, stream admission rejection,
  and RST rate limit.
- Preserve endpoint context, negotiated protocol, failure layer, retryability,
  status/status class when present, and low-cardinality error class.
- Redact Authorization, Cookie, Set-Cookie, and X-API-Key header values.
- Redact URL query strings.
- Never quote response/request bodies in pretty or JSON-style projections.
- Cross-tab H-D1, H-D5, Pool, and Track B outcomes so they map without class
  collisions.

## Candidate Ledger

| Candidate | Why plausible | Evidence needed | Status |
| --- | --- | --- | --- |
| A. One eta-http payload in the typed failure channel | Keeps Eta generic and lets retry/OTel/debugging share the same structured value | Fixtures show all variants, redaction, low-cardinality fields, Cause.t leaf fit | Accepted |
| B. Add HTTP constructors to Eta.Cause | Centralizes pretty-printing | Would bloat Eta with protocol-specific state and break the repo boundary | Rejected by boundary |
| C. Stringly errors plus pretty Cause.t output | Smallest immediate surface | Cannot drive retry or OTel semconv without parsing strings | Rejected by criteria |

## Command

    nix develop -c dune exec scratch/eta_http_research/h_d_errors/fixtures.exe
