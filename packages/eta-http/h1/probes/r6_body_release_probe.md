# R6 h1 Body Release Probe

## Question

Does the eta-http h1 pool hold a checked-out connection until the response
body is consumed or explicitly discarded?

## Implementation

- `Eta_http.H1.Client.request_with_pool` starts an owner effect around
  `Eta.Pool.with_resource`.
- The owner sends the response over `Eta.Channel`, then waits for a body
  release acknowledgement before the pool finalizer can return the connection.
- `Eta_http.Body.Stream.read_all` releases at EOF. `Body.Stream.discard`
  releases without reading the body.
- If the request is cancelled before a response is returned, the response and
  release channels are closed. The owner will not keep the checkout after its
  in-flight flow read/write completes.

## Evidence

```sh
nix develop -c dune runtest packages/eta-http --force
nix develop -c dune exec scratch/eta_http_v1/probes/openai_401.exe
nix develop -c dune exec scratch/eta_http_v1/probes/reach_13.exe
```

Observed:

```text
eta-http: 24 tests passed
eta_http_openai_401 outcome=ok status=401 body_bytes=151 protocol=h1
eta_http_s1_reach_summary verdict=PASS targets=13 failed=<none> protocol=h1 policy=tls12_ecdhe_aead_only
```

Focused tests:

- `body release once` proves `Body.Stream` release is idempotent.
- `pool holds checkout until body EOF` proves `Eta.Pool.stats.active = 1`
  after response headers are returned and `idle = 1` only after EOF.
- `pool discard releases checkout` proves explicit discard returns the
  checkout without reading the in-memory body.

## Verdict

PARTIAL PASS for S1 h1.

The h1 package code now matches the H-D2a owner-fiber lifecycle for EOF and
discard. The OpenAI 401 and 13-endpoint reach probes exercise the same public
h1 path against real peers, but they do not introspect pool stats.

R6 remains open for cancellation while reading a body and for the S2 h2
stream-permit lifecycle.

## Disproof Status

| Disproof signature | Status |
| --- | --- |
| Real h1 connection lifecycle differs from the fake H-D2a model | Not falsified for EOF/discard; deterministic h1 pool stats prove the owner checkout is held until body release. |
| Release paths leak under realistic cancellation patterns | Still open; S1 has pre-response channel cleanup but does not cancel in-flight socket IO. Mid-body cancellation needs a focused probe. |
| h2 stream permits fail to release through the same public body API | Not tested in S1; S2 owns h2 verification. |
