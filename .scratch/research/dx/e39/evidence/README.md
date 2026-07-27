# DX-E39 Phase-0 Evidence

- `source-audit.md` — exhaustive consumer map, dependency map, tracing fault-line
  check, `all` special behavior, and honesty audit.
- `cost-before.json` / `cost-baseline.md` — raw and summarized BEFORE benchmark.
- `cost-after-s.json` / `cost-measurement.md` — raw S run and calculated deltas.
- `dishonesty-master.txt` — executable false declaration on the master-side API.
- `describe-master.txt` — byte source for later Endpoint-S snapshot parity.
- `describe-slim.txt` / `snapshot-parity-s.txt` — byte-identical Endpoint-S proof.
- `dishonesty-s-compile.txt` — the committed master probe rejected by S because
  `~capabilities` no longer exists.
- `gates-s/` — exact Endpoint-S gate commands and statuses.
- `gates-r/` — exact Endpoint-R gate commands and statuses.
- `tracing-r.md` — mechanical and executable proof that tracing survives removal
  of the internal static-name list.

The dishonest probe source is
`test/effect_introspection/dishonest_expert_make.ml`; its test demonstrates an
`Expert.make ~capabilities:[]` leaf that sleeps while `audit.uses_clock=false`.
