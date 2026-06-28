# R8 Server Push And PRIORITY Probe

> Historical probe note: commands below record original local probe runs; maintained verification now lives in `test/`, `http-testsuite/`, and package Dune gates.


## Question

Does the pinned `ocaml-h2` package expose enough behavior for eta-http to
disable server push, reject illegal PUSH_PROMISE frames, and tolerate
PRIORITY frames without owning HPACK/frame parsing itself?

## Implementation

- `.scratch/eta_http_v1/probes/h2_r8_push_priority.ml` drives an in-process
  `H2.Client_connection` and `H2.Server_connection` with the same Sans-IO
  read/write loop used by R7.
- The positive path creates a client with no push handler, which causes
  `ocaml-h2` to advertise `SETTINGS_ENABLE_PUSH=0`; the server request
  handler calls `Reqd.push` and observes `Push_disabled`.
- The negative PUSH_PROMISE path feeds a raw PUSH_PROMISE frame to the
  disabled client and observes a connection-level `ProtocolError` reasoned
  as push-disabled.
- The PRIORITY path feeds well-formed PRIORITY frames to both server and
  client state machines and verifies they do not emit GOAWAY/error closure.

## Evidence

```sh
nix develop -c dune exec .scratch/eta_http_v1/probes/h2_r8_push_priority.exe
```

Observed:

```text
eta_http_r8_push_priority verdict=PASS push_disabled=true forced_push_protocol_error=true priority_tolerated=true
```

## Verdict

PASS for R8.

`ocaml-h2` exposes the push-disable and PRIORITY behavior eta-http needs for
S2. Eta-http can rely on `Config`/initial SETTINGS plus `Reqd.push` for
normal push-disable enforcement, and can map disabled-client PUSH_PROMISE
connection errors at the adapter boundary.

## Disproof Status

| Disproof signature | Status |
| --- | --- |
| `ocaml-h2` cannot advertise push disabled through initial SETTINGS | Not falsified; a no-push-handler client causes server `Reqd.push` to return `Push_disabled`. |
| A received PUSH_PROMISE cannot be detected as a protocol error | Not falsified; a raw PUSH_PROMISE against a disabled client reports `ProtocolError`. |
| PRIORITY frames crash or force GOAWAY/error closure | Not falsified; well-formed PRIORITY frames are tolerated by both client and server state machines. |
| eta-http h2 adapter behavior is complete | Still open; typed error mapping and live Eio/TLS dispatch remain S2 implementation work. |
