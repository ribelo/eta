# DX-E39 evidence index

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
- `describe-sprime.txt` / `snapshot-parity-sprime.txt` — byte-identical
  master↔S′ `describe` output.
- `representation-sprime.md` — two-field `Custom` and no-names proof.
- `gates-sprime/` — exact S′ gate commands and statuses.

The dishonest probe source was committed at pre-deletion commit `ba1275f4` as
`test/effect_introspection/dishonest_expert_make.ml`; S deleted that obsolete
source after recording its runtime output and compile rejection.
