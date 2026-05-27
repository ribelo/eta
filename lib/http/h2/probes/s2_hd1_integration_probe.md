# S2 H-D1 Real H2 Integration Probe

## Question

Can the H-D1 stream-lifecycle obligations run against real `ocaml-h2`
client/server state instead of the fake frame multiplexer?

## Implementation

- `Eta_http.H2.Multiplexer.request` gates a request through eta-http
  `Stream_state` before calling `H2.Client_connection.request`.
- Eta_stream-level h2 errors mark the eta-http stream as remotely reset.
- Response body release closes the h2 body reader when it is still open, then
  releases the eta-http stream permit.
- Tests pump real `H2.Client_connection` and `H2.Server_connection` bytes
  through the same h2 writer/read helpers used by the adapter probes.

## Evidence

```sh
nix develop -c dune runtest lib/http --force
```

Observed:

```text
h2-writer / blocked write teardown: PASS
h2-multiplexer / 100 concurrent GETs: PASS
h2-multiplexer / upload flow-control resumes: PASS
h2-multiplexer / server reset admission release: PASS
h2-multiplexer / client cancel releases stream: PASS
```

## Verdict

PASS for the H-D1 stress rows ported to real `ocaml-h2` state.

The fake H-D1 rows for flow-control stall/resume, RST cleanup,
ACTIVE+CANCELLED rapid-reset admission, and mid-flight client cancellation now
have real h2 coverage through eta-http's mux request wrapper. The S2 smoke
shape also has a deterministic 100-concurrent-GET fixture on one h2 client
connection.

The blocked-writer teardown row is covered by the Eta-effect writer loop:
`Eta_http.H2.Writer.run_client` drives a real `H2.Client_connection`
write operation, the test blocks the write callback, and
`Eta.Supervisor.scoped` exits by cancelling the writer child.

This is still not the complete public h2 client. Real Eio socket read/write
lifecycle and h1/h2 transport dispatch remain separate S2 work.

## Disproof Status

| Disproof signature | Status |
| --- | --- |
| Real `ocaml-h2` callbacks cannot be bound to eta-http stream permits | Not falsified; mux request wrapper tracks stream ids and releases permits. |
| Real h2 flow-control stalls permanently block other progress | Not falsified; upload stalls until server body reads resume, then completes. |
| Server RST frees admission before local release | Not falsified; reset streams remain cancelled/live and reject new admissions until release. |
| Client body cancellation leaks stream metadata or corrupts the connection | Not falsified; active release queues local reset, drops live state, and a follow-up GET succeeds. |
| Blocked writer teardown is solved | Not falsified at writer-loop level; supervised writer teardown cancels a blocked write callback. |
