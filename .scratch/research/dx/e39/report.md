# DX-E39 report — audit-slim race

## Outcome

Both required endpoints are implemented as consecutive, independently
reviewable ranges:

| Endpoint | Commit / range | Result |
| --- | --- | --- |
| S — slim | `7d8e5236..f136a68d` (code at `6c51b9e3`) | removes audit/footprints/declarations/assertions and `all` introspection special-case; keeps `describe`/`collect_names` |
| R — remove | `f136a68d..82d17297` | additionally removes `describe`, `collect_names`, and propagated static names |

The decision dossier is [in `dossier/`](dossier/README.md). My recommendation is
**Endpoint S**: it removes the untrustworthy assurance vocabulary and captures
the measured footprint cost while preserving the evidenced honest
printable-blueprint use. R is green and materially smaller, so independent
review can choose it if the incomplete `collect_names` structural case is judged
insufficient.

## Phase-0 evidence

The exhaustive [source audit](evidence/source-audit.md) found:

- no in-repository real application/runtime consumer of `audit`, `describe`,
  `collect_names`, or the audit assertions (the census does not establish
  absence among external consumers);
- one raw-`audit` package-boundary check, dominant audit self-tests, and public
  docs/teaching uses for static names and description;
- seven public assertions rather than the objective's stated four;
- no runtime tracing reader of the propagated `Custom.names` list;
- `all` aggregated prebuilt-child names and footprints at construction while
  `map_par` did not;
- contracts honestly hedged the static boundary, but `assert_pure_eff` and the
  writable `Expert.make` declaration still sounded/acted like assurances.

The master-side dishonesty probe executed one sleep while reporting
`uses_clock=false`. S rejects the same `~capabilities:[]` syntax.

## Cost result

Protocol and raw values are in [the cost dossier](dossier/cost.md). On the
pre-registered 100,000-iteration `map_bind_preserve` row:

- allocated words: 2,200,014 → 1,400,014 (**-36.36%**);
- warm-up-discarded median time: 6,357,551 ns → 2,879,977 ns (**-54.70%**);
- map/bind control allocation: 600,014 → 600,014 (**0.00%**).

The 10% first-class threshold fired. The exact eight-word saving per preserve
layer matches removal of the footprint record/header and `Custom` field.

## Regression evidence

- BEFORE and S `describe` snapshot hashes are identical and `cmp` reports
  byte-identical: [snapshot artifact](evidence/snapshot-parity-s.txt).
- S makes the dishonest capability declaration unwritable:
  [compile artifact](evidence/dishonesty-s-compile.txt).
- R deletes `Custom.names` while runtime span naming stays direct and its named
  span witnesses pass: [tracing artifact](evidence/tracing-r.md).
- Law-bearing removals have explicit S and R dispositions in the census-complete
  `LAWS.md` registry.

## Gates

All mandatory gates passed on **both** endpoint trees:

| Gate | S | R |
| --- | ---: | ---: |
| `nix develop -c dune build @install` | 0 | 0 |
| `nix develop -c dune runtest --force` | 0 | 0 |
| `nix develop -c eta-oxcaml-test-shipped` | 0 | 0 |
| mainline JS targets, dedicated `_build-mainline` | 0 | 0 |

Exact command/timestamp/status files:
[`evidence/gates-s/`](evidence/gates-s/README.md) and
[`evidence/gates-r/`](evidence/gates-r/README.md).

## Prediction score

The sealed journal was not edited. Falsifiable subtotal: **7 hits, 1
partial/miss, 2 misses**.

- Hits: allocation direction and ≥10% threshold; timing direction; consumer
  classifications for audit/describe/collect_names; tracing fault line.
- Partial/miss: an assertion boundary consumer was predicted, but the boundary
  used raw `audit` and assertions had only a self-test.
- Misses: predicted 10–25% allocation and 5–15% timing brackets were both too
  conservative (observed 36.36% and 54.70%).
- Predicted winner S agrees with my recommendation but is not included in the
  empirical subtotal; final promotion is the independent review outcome.

Full scoring: [dossier/recommendation.md](dossier/recommendation.md).

## Diff and census summary

- Semantic merge-base→S: 76 files, +1,398/-975 overall;
  product/test/docs/examples/bench subset: 58 files, +236/-777.
- S→R: 29 files, +154/-389 overall;
  product/test/docs/examples/bench subset: 21 files, +21/-316.
- `Custom` fields: 4 BEFORE → 3 S → 2 R.
- E39 public cluster: audit entries 2→0→0; tree/aggregate inspection vals
  2→2→0; assertions 7→0→0; Expert metadata parameters 3→1→0.

Literal current-master stats and the merge-base explanation are preserved in
[dossier/diff-stats.txt](dossier/diff-stats.txt).

## Deviations

1. Removed all seven actual public assertions, not only the four stated in the
   objective.
2. Migrated `blocking_common`'s raw-audit boundary check to ordinary execution
   behavior.
3. Corrected allocation measurement to `Gc.counters` with promotion subtraction
   before collecting either side; benchmark protocol was then frozen.
4. S removes `all`'s child-name special case while keeping general static-name
   propagation for `collect_names`; R removes the mechanism completely.
5. Master advanced after the branch merge-base only in a scope-fenced state
   path. That path was not read or touched; semantic review stats use the fixed
   merge-base and literal master stats are also recorded.
6. A post-implementation read-only dossier reviewer reported that one broad
   symbol grep inadvertently emitted three matching lines from the prohibited
   `docs/research/` tree. It did not open or modify those files, did not report
   their contents to this executor, and did not use them in its conclusions.
   This occurred after predictions, both endpoints, measurements, and the
   dossier were complete; it cannot have influenced the sealed prediction or
   implementation, but is disclosed as a scope-process incident.
