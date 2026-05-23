# H-D5 ALPN Bootstrap

## Verdict

The ALPN dispatch state-machine proof passes against the fake local ALPN
server. Production TLS remains out of scope; this lab exercises the internal
resource topology and concurrent first-arrival collapse.

Command:

```text
nix develop -c dune exec scratch/eta_http_research/h_d5_alpn_bootstrap/stress.exe
```

Evidence:

```text
PASS single request opens one h2 connection cleanly
PASS two concurrent h2 requests share one multiplexer
PASS pending first-arrivals collapse and free redundant connection
PASS third request waits for in-flight ALPN and dispatches h2
PASS unexpected h1 ALPN falls back to pool dispatch
h_d5_alpn_bootstrap stress passed
```

Implementation notes:

- Pending_connection stays internal to the scratch dispatch lab; request
  callers only see h1/h2 response classification.
- h1 dispatch uses Eta.Pool.with_resource over one host pool.
- h2 dispatch creates one single-cell multiplexer per host and feeds it through
  the H-D1 Multiplexer/Fake_multiplex_connection/Writer_fiber modules.
- Runtime.drain is called by the stress harness after each fixture, so the h2
  owner daemon has to exit before the fixture can pass.
