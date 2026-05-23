# H-Q Envelope Lab

This lab bounds the eta-http v1 malicious-server HTTP/2 envelope against the
current scratch SUT:

- H-D1 multiplexer for stream admission, stream release, RST, PING, DATA, and
  WINDOW_UPDATE paths.
- H-D-Errors for typed error mapping.
- eta-http adapter policy rows for attacks that require byte-level HTTP/2
  parser hooks not present in H-D1.

The lab intentionally preserves deferred rows. A deferred row means the attack
class is real, but the current scratch SUT lacks the capability needed to drive
it honestly.

## Run

```sh
nix develop -c dune exec scratch/eta_http_research/h_q_envelope/fixtures.exe
```

The runner samples all attacks once per second for 30 seconds and writes:

```text
scratch/eta_http_research/h_q_envelope/monitoring.csv
```

## Files

| File | Purpose |
| --- | --- |
| `malicious_server.ml` | Shared attack catalogue and typed-error mapping. It is the current malicious-server skeleton until raw ocaml-h2 hooks are promoted. |
| `monitor.ml` | RSS, GC live words, fd count, modeled fiber count, CPU, allocator, and stream-state sampler. |
| `attack_runner.ml` | Drives every attack row and writes `monitoring.csv`. |
| `q2_*.ml` | Stream-level H-Q2 attack fixtures. |
| `q5_*.ml` | Frame/protocol-level H-Q5 attack fixtures. |
| `q_alloc_pressure.ml` | Cross-cutting allocator-pressure falsifier. |
| `defaults.md` | Public eta-http config knobs and default rationale. |
| `results.md` | Verdict table and raw command output. |

## Limits

H-D1 is not a byte-level HTTP/2 parser. It has no GOAWAY, SETTINGS, HPACK,
Huffman, or header-name/value representation. Those rows are recorded as
deferred with the missing capability named.

The fiber count is modeled because Eta does not expose a runtime fiber census.
The lab samples real Linux fd count, RSS, OCaml live words, CPU time, and
allocator counters.
