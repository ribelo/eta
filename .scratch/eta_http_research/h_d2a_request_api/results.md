# H-D2a Results

Verdict: PASS.

The request API can hide h1 versus h2 from callers. The same `Caller_demo.run` function runs against both clients and produces byte-identical observable caller output. Body consumption, body discard, and body-read cancellation all release the protocol-specific lease.

## API Surface

```ocaml
val request : Client.t -> Request.t -> (Response.t, error) Effect.t
```

`Response.t` exposes:

- `status : int`
- `headers : (string * string) list`
- `body : Stream.t`
- `trailers : unit -> (headers, error) Effect.t`

`rg "Client\.protocol|\bH1\b|\bH2\b" scratch/eta_http_research/h_d2a_request_api/caller_demo.ml` returns no matches.

## Lifecycle Evidence

Normalized stats use the same fields for both protocols:

- `active`: checked-out h1 connections or active h2 stream permits.
- `idle`: idle h1 pool entries or remaining h2 stream capacity.
- `capacity`: h1 pool size or h2 max concurrent streams.
- `opened`: opened h1 connections or opened h2 streams.
- `released`: response body release count.

Focused run:

```text
nix develop -c dune exec scratch/eta_http_research/h_d2a_request_api/fixtures.exe
TRACE small status=200 body=small trailer=small-done
TRACE echo status=200 body=echo:alphabeta trailer=echo-done
TRACE stream first=part-1 trailer=stream-done
TRACE slow cancelled=response_body_idle_timeout
H1 protocol=h1 active=0 idle=1 capacity=2 opened=1 released=4
H1 h1_pool active=0 idle=1 waiting=0 opened=1 closed=0
H1 h1_server requests=4 opened=1 closed=0
H2 protocol=h2 active=0 idle=8 capacity=8 opened=4 released=4
H2 h2_streams active=0 live=0 opened=4 completed=4 local_resets=0
H2 h2_admission rejected=0 max_inflight=1 remote_resets=0
H2 h2_server opened=1 closed=0
PASS same caller trace across h1 and h2
PASS h1 releases every response body
PASS h2 releases every stream permit
PASS h1 pool checkout is held while body is open
PASS h2 stream permit is held while body is open
PASS h-d5 library exposes ALPN dispatcher for reuse
h_d2a_request_api fixtures passed
```

Guard runs after changing H-D1 and H-D5 scratch code:

```text
nix develop -c bash -lc 'dune exec scratch/eta_http_research/h_d1_dogfood_multiplex/stress.exe && dune exec scratch/eta_http_research/h_d5_alpn_bootstrap/stress.exe'
PASS flow-control blocks at 8KB window
PASS flow-control resumes after WINDOW_UPDATE
PASS rst cleanup returns to baseline
PASS mid-flight cancellation queues RST and cleans streams
PASS deadlock teardown is not extended by blocked writer
PASS rapid reset admission counts active and cancelled
h_d1_dogfood_multiplex stress passed
PASS single request opens one h2 connection cleanly
PASS two concurrent h2 requests share one multiplexer
PASS pending first-arrivals collapse and free redundant connection
PASS third request waits for in-flight ALPN and dispatches h2
PASS unexpected h1 ALPN falls back to pool dispatch
h_d5_alpn_bootstrap stress passed
```

Shipped Eta package guard:

```text
nix develop -c dune runtest --force packages/eta/test
Test Successful in 1.423s. 156 tests run.
```

`nix develop -c dune build` is still blocked by pre-existing default-alias
scratch and bench targets that reference the old `effet` / `ppx_effet`
libraries and the older `Effect.sync "name"` call shape. The failure is not
from H-D2a targets; the focused H-D2a executable and H-D1/H-D5 guards build
and pass.

## Decision

Accept the request-layer abstraction. Do not try to force h1 connection leases and h2 stream permits into one public pool primitive.

Implementation notes:

- h1 uses an owner fiber around `Pool.with_resource`; the owner sends the response and waits for body release before the pool finalizer returns the connection.
- h2 uses `Multiplexer.request_open`; the stream stays active after response headers and is released by the body stream finalizer.
- `Stream.read_all` scopes a release finalizer, so `timeout_as` cancellation mid-body releases the underlying h1 checkout or h2 stream permit.
- `Stream.discard` and EOF after the final chunk call the same idempotent release path.

Residual risk: the fake h2 server models response bytes above H-D1 frames. H-Q1/H-Q2/H-Q3 should continue testing frame-level attack and cleanup behavior directly against the H-D1 multiplexer.
