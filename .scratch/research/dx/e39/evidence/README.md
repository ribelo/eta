# DX-E39 Phase-0 Evidence

- `source-audit.md` — exhaustive consumer map, dependency map, tracing fault-line
  check, `all` special behavior, and honesty audit.
- `cost-before.json` / `cost-baseline.md` — raw and summarized BEFORE benchmark.
- `dishonesty-master.txt` — executable false declaration on the master-side API.
- `describe-master.txt` — byte source for later Endpoint-S snapshot parity.

The dishonest probe source is
`test/effect_introspection/dishonest_expert_make.ml`; its test demonstrates an
`Expert.make ~capabilities:[]` leaf that sleeps while `audit.uses_clock=false`.
