# DX-E28 Follow-up 1 — Sealed Micro-predictions

This entry was written after reading `followup-1.md` and before inspecting or
changing implementation/tests for unified admission. It is immutable after the
sealing commit. Actuals and scoring belong in `report.md`.

## Contract predictions

| Prediction | Expected result |
|---|---|
| Default admission | A probe with at least nine blocked children observes an exact peak of 8. |
| Explicit full fan-out | Nine rendezvous participants deadlock under omission but all complete with `~max_concurrent:9`; only the positive explicit-bound form will be executed. |
| Input order | Worker admission does not change input-order result assembly, including reverse completion. |
| Fail-fast/cleanup | The first observed failure stops admission, cancels admitted siblings, and waits for their finalizers as the old engine did. |
| Empty input | `all []` still succeeds with `[]` and creates no workers. |
| Invalid bounds | Zero and negative bounds raise `Invalid_argument` when the blueprint is constructed, including for an empty input. |
| Introspection | `all` still aggregates every prebuilt child's static names and capability footprint before interpretation; `describe` remains an opaque `Custom("Effect.all")` leaf. |
| Mapper construction | `map_par` remains lazy in `f`; sharing admission machinery will not force the mapper during blueprint construction. |
| JS stream migration | `map_effect` preserves chunk values, input order, typed failures, and lazy callback evaluation, while changing peak admission for chunks over eight from chunk length to 8. |

## Predicted implementation shape

One internal indexed worker scheduler will accept an item array and an effect
builder. `all` will pass identity over its prebuilt effect array; `map_par` will
pass its mapper. Public construction remains separate so `all` can preserve
`concat_names` and `concurrent_footprint`, while `map_par` keeps only its own
concurrency footprint because its mapper is opaque.

## Existing behavior predicted to change by design

The audit census predicts these existing executable sites can observe lower
admission because they pass more than eight children to `all`:

- `test/core_common/effect_common_suites.ml` — 128 concurrent `fresh` pulls.
- `test/core_common/effect_interruptible_shared.ml` — 17 interruptible values.
- `test/core_common/stress_common_suites.ml` — 20 pool workers and 30 semaphore workers.
- `test/http/test_eta_http_h2_connection.ml` — 10 concurrent streams.
- `test/laws/law_properties.ml` — generated lists may reach above eight and the queue close-wrapper aggregate has more than eight checks.
- `bench/runtime_concurrency/runtime_concurrency.ml` — the 64-child `all` and `all_heavy` cases become cap-eight benchmarks by default.

Sites with six or eight children are predicted to keep their effective peak
because the default bound is not lower than the input size. Barrier/coordinator
tests that require every participant live will need the explicit length bound;
ordinary independent work should continue to pass while running in waves.

## Risk predictions

- The highest implementation risk is fail-fast while workers are pulling new
  indices: no task may be admitted after stop wins, and causes/finalizers must
  retain current behavior.
- The highest contract risk is users reading “concurrent” as “all admitted.” The
  plain deadlock warning plus the nonempty full-fan-out recipe should catch a
  nine-way interdependent barrier in review.
- The JS mainline suite is expected to need a focused `map_effect` test because
  existing tests may cover values but not prove default cap-eight admission.

## Predicted scoring

I expect all nine contract predictions above to hit, at most two existing tests
to require an explicit full-fan-out bound, and no production caller other than
`lib/js_stream/eta_js_stream.ml` to require migration for correctness.
