# H-S1: ocaml-h2 sans-IO from Eio

This lab tests whether `H2.Client_connection` can be driven directly as a
sans-IO state machine, without inheriting an `httpun` runtime adapter.

## Proof Ladder

- P0: dependency availability under the pinned OxCaml switch.
- P1: in-process client/server pump using only h2's sans-IO operations.
- P2: Eio flow adapter against a local fixture.
- P3: full Stage 2 matrix from `Eta-0gy` (currently partial: concurrent
  GETs, POST body, response trailers, server RST_STREAM, error-GOAWAY
  admission gating, and client mid-body cancellation pass; graceful GOAWAY
  last-stream-id cutoff remains unproven).
- P4: TLS production smoke, after the TLS dependency issue is solved.

This directory is currently a P1 lab. It is not the final `V-Http-S1`
verdict.

## Falsifier

The P1 harness fails if a client request cannot be expressed through
`Client_connection.request`, if server responses cannot be handled through
`Server_connection.create`, or if the read/write pump requires an `httpun`
runtime adapter.
