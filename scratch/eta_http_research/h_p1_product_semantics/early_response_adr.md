# ADR: Early Response During Upload

Status: Accepted for eta-http v1.

## Decision

eta-http v1 handles an HTTP/1.1 interim `100 Continue` by skipping it and
returning the final response. It does not wait for `100 Continue` before
uploading a request body, and it does not claim early-response draining while a
request body is still uploading.

If the peer closes the connection while eta-http is writing request headers or
body bytes, eta-http maps that failure to a typed Connection_closed error during
the HTTP request layer. If a response is received after the request has been
written, it is returned normally.

## Evidence

packages/eta-http/h1/write.ml maps flow write exceptions to
Connection_closed { during = Http_request }. The current h1 request loop writes
the request before reading the response head, then skips non-final
informational responses before returning the final response. The HTTP/2 path
writes the request body through ocaml-h2 and maps stream/connection errors to
typed protocol or closed-connection errors.

## Consequences

Callers that need strict early 413 handling before upload completion should use
replayable/idempotent request bodies and retry policy at the application
boundary. eta-http v1's contract is clean typed failure or normal final
response, not upload-drain recovery.
