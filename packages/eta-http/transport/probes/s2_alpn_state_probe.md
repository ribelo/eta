# S2 ALPN State Probe

## Question

Can eta-http represent the H-D5 ALPN bootstrap decision without raw Eio
coordination primitives and before the full h1/h2 dispatcher lands?

## Implementation

- `Eta_http.Transport.Alpn` is a pure state machine.
- `begin_request` returns one `Leader` while no protocol route exists.
- Concurrent first arrivals see `Wait` on the same pending id and increment
  `redundant_cancelled`, matching the H-D5 redundant-connection collapse
  rule.
- `resolve` installs the negotiated `H1` or `H2` route only for the current
  pending id. Stale pending completions are ignored.
- `protocol_of_alpn` maps `Some "h2"` to h2, `Some "http/1.1"` and
  `None` to h1 fallback, and rejects unknown ALPN names.

## Evidence

```sh
nix develop -c dune runtest packages/eta-http --force
```

Focused tests:

- `alpn / pending first-arrivals collapse`
- `alpn / stale resolution and decode`

Observed:

```text
eta-http: 32 tests passed
```

## Verdict

PASS for the pure ALPN state-machine cut.

This does not complete transport dispatch. The next S2 work must attach
these decisions to real h1 pool and h2 multiplexer resources, then prove the
same caller path selects h1 or h2 without application branching.

## Disproof Status

| Disproof signature | Status |
| --- | --- |
| Pending first arrivals cannot collapse without raw Eio primitives | Not falsified; the pure state machine records leader/waiter/redundant-cancel decisions. |
| Stale ALPN completions can overwrite the installed route | Not falsified; stale pending resolution returns `Ignored`. |
| ALPN dispatch is complete | Still open; resource ownership and real h1/h2 dispatch are not wired. |
