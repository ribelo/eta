# Recommendation and prediction score

## Recommendation: promote Endpoint S

Between the two built endpoints, S is the stronger contract/cost trade:

1. It deletes every capability assurance that the API itself admitted could be
   wrong, all seven assertion names built on those flags, and the writable
   `Expert.make` lie. The dishonest probe becomes syntactically impossible.
2. It captures the measured win: 36.36% fewer allocated words and 54.70% lower
   median construction time on the pre-registered primary workload, with an
   allocation-identical control. R shares that footprint deletion, so this
   before/S evidence does not differentiate R from S.
3. It preserves one named structural rationale for external consumers: a
   deterministic, non-evaluating view of a blueprint value. Snapshot parity
   proves the teaching/debug output is unchanged, and its contract explicitly
   exposes the opaque/bind boundary rather than claiming runtime completeness.
4. R is mechanically cleaner (one fewer `Custom` field, zero name propagation,
   295 net lines removed from product/test/docs/examples/bench), and no real
   production consumer of either public inspection function was found. That is
   credible R-side evidence. But no R-over-S cost was measured, while R removes
   the only evidenced printable-blueprint facility. Under the external-consumer
   model, zero in-repo application calls cannot outweigh that structural need by
   itself.

The weakest part of S is `collect_names`: it retains 12 storage sites and an
explicitly incomplete static list. If independent review judges that preflight
list's structural need insufficient, R is fully gated and reviewable. The
recommendation remains S because the endpoint race bundles that list with the
honest `describe` facility and the measured cost win is already common to both.

## Sealed-prediction score

The immutable predictions are in `../journal.md`. Scoring separates direction,
bracket, and classifications rather than retrofitting the prediction.

| Prediction | Evidence | Score |
| --- | --- | --- |
| S is preferred | recommendation above; final promotion belongs to independent review | provisional, not empirically scoreable |
| Footprint removal lowers allocated words | primary -36.36% | **hit** |
| Allocation bracket 10–25% | observed 36.36% | **miss** |
| Allocation meets 10% threshold | 36.36% | **hit** |
| Construction time improves | primary -54.70% | **hit** |
| Time bracket 5–15% | observed 54.70% | **miss** |
| `audit` consumers are tests/boundary/docs, no real runtime use | exhaustive census matches | **hit** |
| `describe` is tests/docs with a teaching/debug structural need, no real runtime use | exhaustive census matches | **hit** |
| `collect_names` is tests/docs/internal support, no real runtime use | exhaustive census matches | **hit** |
| assertions include a boundary consumer | assertions had only one self-test; boundary used raw `audit` | **partial/miss** |
| runtime tracing does not read propagated names | source map plus R tracing gates | **hit** |

Falsifiable subtotal: **7 hits, 1 partial/miss, 2 misses**. The endpoint-winner
prediction is reported but not counted because the orchestrator's independent
promotion decision is the outcome.

## Deviations and surprises

- The objective said four audit assertions; the public MLI exposed seven. All
  seven were treated as the intended cluster and removed.
- The named `blocking_common` boundary used raw `Effect.audit`, not an
  `Eta_test` assertion. It was migrated to an ordinary behavior test.
- The cost brackets were materially too conservative, though direction and
  threshold were correct.
- The benchmark allocation metric was fixed before baseline collection to use
  `Gc.counters` and subtract promoted words; no before/after protocol changed.
- `all`'s documented special case included both child-name and footprint
  aggregation. S removed both for `all`; general name propagation remained only
  to support its retained `collect_names` contract.
- Current `master` advanced after the E39 merge-base in a scope-fenced state
  file. The dossier records both literal `master..S` stats and the semantic
  merge-base (`7d8e5236`) range without reading or touching the fenced file.
