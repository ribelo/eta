# S2 H2 Eta_stream State Probe

## Question

Can eta-http own public HTTP/2 stream lifetime with `Portable.Atomic`
per-stream state while keeping admission bounded by ACTIVE+CANCELLED streams?

## Implementation

- `Eta_http.H2.Stream_state` wraps `Eta_http.H2.Admission` permits.
- Each stream stores its public lifecycle status in `Portable.Atomic`:
  `Active`, `Remote_reset`, `Complete`, or `Released`.
- Remote reset moves the stream from active to cancelled admission, but the
  stream remains live until response-body release.
- Completed streams release without queuing local RST; still-active streams
  release by queuing local RST intent for the future writer.

## Evidence

```sh
nix develop -c dune runtest lib/http --force
```

Observed:

```text
h2-stream-state / release decisions: PASS
h2-stream-state / close releases live state: PASS
```

## Verdict

PASS for the local S2 stream-state cut.

This does not close the full h2 adapter. It proves the lifecycle component
needed by the adapter can be expressed without raw Eio synchronization or raw
`Atomic.t`, and that it preserves the H-D1 ACTIVE+CANCELLED invariant already
proved by the admission counter.

## Disproof Status

| Disproof signature | Status |
| --- | --- |
| Per-stream state cannot be represented with OxCaml portable atomics | Not falsified; `Portable.Atomic` compiles in `h2/stream_state.ml`. |
| Remote reset frees admission before local body release | Not falsified; tests prove cancelled streams still count as inflight. |
| Completed response release queues a spurious local RST | Not falsified; completed release returns `No_rst`. |
| Full h2 stream-permit R6 is closed | Still open; live `ocaml-h2` response bodies are not wired to this state yet. |
