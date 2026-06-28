# R6 h1 Body Release Probe

> Historical probe note: commands below record original local probe runs; maintained verification now lives in `test/`, `http-testsuite/`, and package Dune gates.


## Question

Does the eta-http h1 pool release checked-out connections exactly when the
response body is consumed, explicitly discarded, or the caller cancels before
the response arrives?

## Implementation

- `Eta_http_eio.H1.Client.request_with_pool` starts an owner effect around
  `Eta.Pool.with_resource`.
- The owner sends the response over `Eta.Channel`, then waits for a body
  release acknowledgement before the pool finalizer can return the connection.
- `Eta_http.Body.Stream.read_all` releases at EOF. `Body.Stream.discard`
  releases without reading the body.
- If the request is cancelled before a response is returned, the request scope
  sends a cancel signal to the owner and closes the response/release channels.
  The owner races in-flight socket work against that signal, marks the
  connection unreusable, closes the flow best-effort, and lets
  `Eta.Pool.with_resource` release the checkout.

## Evidence

```sh
nix develop -c dune runtest lib/http --force
nix develop -c dune exec .scratch/research/evidence/eta_http_v1/probes/openai_401.exe
nix develop -c dune exec .scratch/research/evidence/eta_http_v1/probes/reach_13.exe
```

Observed:

```text
eta-http: 29 tests passed
eta_http_openai_401 outcome=ok status=401 body_bytes=151 content_length="151" transfer_encoding="<none>" protocol=h1
eta_http_s1_reach_summary verdict=PASS targets=13 failed=<none> protocol=h1 policy=tls12_ecdhe_aead_only
```

Focused tests:

- `body release once` proves `Body.Stream` release is idempotent.
- `pool holds checkout until body EOF` proves `Eta.Pool.stats.active = 1`
  after response headers are returned and `idle = 1` only after EOF.
- `pool discard releases checkout` proves explicit discard returns the
  checkout without reading the in-memory body.
- `pool cancellation releases checkout` proves caller cancellation before
  response headers does not leave an active h1 pool checkout behind.

## Verdict

PASS for S1 h1.

The h1 package code now matches the H-D2a owner-fiber lifecycle for EOF,
discard, and pre-response caller cancellation. The OpenAI 401 and 13-endpoint
reach probes exercise the same public h1 path against real peers, but they do
not introspect pool stats.

S1 bodies are eager fixed-length byte buffers, so true mid-body streaming
cancellation reopens with S3 streaming bodies. R6 remains open for the S2 h2
stream-permit lifecycle.

## Disproof Status

| Disproof signature | Status |
| --- | --- |
| Real h1 connection lifecycle differs from the fake H-D2a model | Not falsified for S1 h1; deterministic pool stats prove the owner checkout is held until EOF/discard and released after pre-response cancellation. |
| Release paths leak under realistic cancellation patterns | Not falsified for S1 h1 pre-response cancellation; the owner races socket work against caller cancellation and the focused test proves active checkout returns to zero. True streaming-body cancellation reopens in S3. |
| h2 stream permits fail to release through the same public body API | Not tested in S1; S2 owns h2 verification. |
