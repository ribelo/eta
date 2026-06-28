# ADR: HEAD And No-Body Response Semantics

Status: Accepted for eta-http v1.

## Decision

eta-http v1 treats HEAD responses as having no response body, even when the
server sends Content-Length or Transfer-Encoding headers. The same no-body rule
applies to 101, 204, and 304 responses.

For HTTP/1.1 informational responses before a final response, eta-http skips
non-final 1xx heads such as `100 Continue` and returns the final response to
the caller.

## Evidence

packages/eta-http/h1/client.ml checks the request method and response status
before constructing a body stream, and it continues past non-final
informational heads. packages/eta-http/client/client.ml applies the no-body
rule on the HTTP/2 path. The h1 client suite includes a HEAD response with
Transfer-Encoding: chunked and verifies that reading the body returns empty
instead of blocking. It also includes a `100 Continue` fixture that verifies
the final 200 response is returned.

## Consequences

Callers can safely read or discard a HEAD response body stream without waiting
for bytes that should not exist. Header metadata such as Content-Length remains
visible on the response.
