# R5 Pool Health Probe

> Historical probe note: commands below record original local probe runs; maintained verification now lives in `test/`, `http-testsuite/`, and package Dune gates.


## Question

Can eta-http safely reuse idle HTTP/1.1 connections without sending
application data during the health check?

## Implementation

- `Eta_http_eio.H1.Client.make_pool` builds an origin-scoped `Eta.Pool`.
- `Eta_http_eio.Client.make_h1` lazily creates one h1 pool per origin.
- The default health check rejects connections that eta-http marked
  unreusable and probes used idle flows with a one-byte buffered read wrapped in
  a 1 ms Eta timeout.
- If the probe times out, the connection is treated as still idle and reusable.
- If the probe sees EOF or unexpected bytes, the pool rejects and closes the
  entry before opening a replacement.

## Evidence

```sh
nix develop -c dune runtest lib/http --force
nix develop -c dune exec .scratch/research/evidence/eta_http_v1/probes/stale_idle.exe
nix develop -c dune exec .scratch/research/evidence/eta_http_v1/probes/openai_401.exe
nix develop -c dune exec .scratch/research/evidence/eta_http_v1/probes/reach_13.exe
```

Observed:

```text
eta-http: 24 tests passed
eta_http_r5_stale_idle verdict=PASS first_body=one second_body=two opened=2 closed=1 health_rejected=1 idle_after_first=1 idle_after_second=1 protocol=h1 peer=loopback_close_after_response
eta_http_openai_401 outcome=ok status=401 body_bytes=151 content_length="151" transfer_encoding="<none>" protocol=h1
eta_http_s1_reach_summary verdict=PASS targets=13 failed=<none> protocol=h1 policy=tls12_ecdhe_aead_only
```

Focused tests:

- `pool reuses healthy idle connection` proves a healthy pooled flow is reused
  without a second TCP open.
- `pool rejects unhealthy idle connection` proves an unhealthy idle entry is
  rejected, closed, and replaced.
- `stale_idle.exe` proves a real loopback h1 peer that closes after the first
  response is rejected by the default non-sending health check before the
  second request is written.

## Verdict

PASS.

The Eta.Pool integration is real and deterministic tests prove both reuse and
health rejection. The loopback stale-idle probe proves the default
non-sending liveness check rejects a real peer that closed an idle connection
before reuse.

A peer can still close after any successful health check, so request-time
`Connection_closed` handling remains part of the safety envelope. That race
does not falsify R5; it is inherent to HTTP/1.1 connection reuse.

## Disproof Status

| Disproof signature | Status |
| --- | --- |
| No reliable mechanism exists | Not falsified. The default probe rejects EOF/unexpected data, accepts timeout as still-idle, and the real loopback stale-idle probe rejects a closed peer before reuse. |
| Pool returns dead connections to callers | Not falsified. Deterministic unhealthy-idle tests and the real loopback stale-idle probe both reject and replace before the next request. |
