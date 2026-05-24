# ADR: HTTP/1.1 Pipelining

Status: Accepted for eta-http v1.

## Decision

eta-http v1 does not support HTTP/1.1 pipelining. It sends one request at a time
per checked-out HTTP/1.1 connection.

Connection reuse is provided by the origin-scoped pool, but a connection is not
returned to the pool until the response body reaches EOF or is discarded.

## Evidence

packages/eta-http/h1/client.ml owns a single request loop per flow checkout.
The h1 pool tests verify that a pooled connection remains active while the body
is open and returns to idle only after EOF or discard.

## Consequences

The client avoids response-order coupling and head-of-line ambiguity from
HTTP/1.1 pipelining. Concurrent request behavior should use multiple pooled
connections or HTTP/2 multiplexing.
