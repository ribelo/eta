# S2 GOAWAY admission probe

> Historical probe note: commands below record original local probe runs; maintained verification now lives in `test/`, `http-testsuite/`, and package Dune gates.


Question: after a peer GOAWAY, does eta-http stop admitting new h2 streams
without turning the condition into stream-admission pressure?

## Evidence

```text
nix develop -c dune exec .scratch/research/evidence/eta_http_research/h_s1_ocaml_h2_eio/goaway_raw_probe.exe
h_s1_goaway_raw last_stream_id=1 stream_errors=0 connection_errors=0 closed_before_flush=false closed_after_flush=true writes_before=1 writes_after=1

nix develop -c dune runtest lib/http --force
h2-multiplexer / GOAWAY rejects new streams: PASS
eta-http: 44 tests passed
```

## Result

`ocaml-h2` does not expose the GOAWAY cutoff before its follow-up writes are
flushed: `is_closed=false` immediately after the raw GOAWAY feed and
`is_closed=true` after the client writer drains. Eta-http therefore uses the
closed h2 client state as the S2 admission cutoff.

The fixture opens stream 1, feeds SETTINGS + GOAWAY(last_stream_id=1), drains
the client writer, then attempts another mux request. The request returns
`Connection_closed`; eta-http stream-state `opened` remains 1 and
`admission_rejected` remains 0.

## Verdict

PASS for S2 post-GOAWAY admission cutoff after the h2 writer observes the
closed client. Earlier last-stream-id selective retry policy is not exposed by
`ocaml-h2` in this cut and remains out of scope for S2.
