# R7 ocaml-h2 API Shape Probe

> Historical probe note: commands below record original local probe runs; maintained verification now lives in `test/`, `http-testsuite/`, and package Dune gates.


## Question

Can the pinned `ocaml-h2` API expose the Sans-IO pieces eta-http needs for
S2 without importing an external runtime adapter?

## Implementation

- `.scratch/research/evidence/eta_http_v1/probes/h2_api_shape.ml` creates an in-process
  `H2.Client_connection` and `H2.Server_connection`.
- The probe issues one client GET with `Client_connection.request`, drains
  `next_write_operation` iovecs into the peer with `read`, schedules response
  body reads with `Body.Reader.schedule_read`, and responds server-side with
  `Reqd.respond_with_string`.
- This is a P1 API-shape proof only. It intentionally does not implement the
  Eta owner fiber, wakeup discipline, h2 pool/permit lifecycle, ALPN dispatch,
  security caps, or live TLS path.

## Evidence

```sh
nix develop -c dune exec .scratch/research/evidence/eta_http_v1/probes/h2_api_shape.exe
```

Observed:

```text
eta_http_r7_h2_api_shape verdict=PASS status=200 body="hello-h2" target=/r7
```

## Verdict

PASS for R7 P1 API shape.

The pinned `h2` package exposes the client/server Sans-IO state machines,
request/response callbacks, iovec write operations, peer `read` entrypoints,
and body reader/writer APIs needed to start the S2 adapter. H-S1's caveat
still applies: eta-http must own Eio flow read/write loops, wakeup discipline,
GOAWAY/admission gating, typed error mapping, and public stream/permit
lifecycle.

## Disproof Status

| Disproof signature | Status |
| --- | --- |
| `ocaml-h2` forces a runtime adapter incompatible with Eta's owner-fiber pattern | Not falsified by P1; direct Sans-IO client/server APIs compile and run. |
| h2 request/response body APIs cannot be driven by eta-http-owned lifecycle code | Not falsified by P1; response body reads and request body close are directly scheduled. |
| GOAWAY/admission and wakeup semantics are fully solved by `ocaml-h2` | Still false; prior H-S1 evidence says eta-http must own those policies. |
