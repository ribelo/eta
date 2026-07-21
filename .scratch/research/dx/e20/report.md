# DX-E20b report — immediate interception results

## Recommendation

**HOLD FOR GATE RE-EVALUATION.** `Keep | Drop | Replace` fixes the public result
representation and preserves every proven E20 behavior. All repository and jsoo
gates pass. The exact watchlist zero-increment bar still fails, however: an
active runtime-local lookup costs ~10.49 minor words per emitted record even
when the callback returns immediate `Keep`.

The two halves are considered separately:

- **Log half:** HOLD. Behavior and representation pass; end-to-end allocation
  remains above the sealed bar.
- **Metric half:** HOLD, not KILL. Per-subtree tenant enrichment remains a
  compelling executable use case and shares the same representation/local
  machinery.

## Current surface

```ocaml
type 'a Effect.intercept = Keep | Drop | Replace of 'a

val Effect.intercept_log :
  (Capabilities.log_record -> Capabilities.log_record Effect.intercept) ->
  ('a, 'err) Effect.t -> ('a, 'err) Effect.t

val Effect.intercept_metric :
  (Capabilities.metric_point -> Capabilities.metric_point Effect.intercept) ->
  ('a, 'err) Effect.t -> ('a, 'err) Effect.t
```

`Keep` and `Drop` are immediate. `Replace value` identifies the only branch that
substitutes a value. The private walkers recurse directly and create no result
wrapper, list node, or continuation per emission.

Census: observability cluster +2 vals / +1 concept, plus one public result type
with three constructors. Public dependencies +0; compatibility paths +0.

## Required gates

| Gate | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo` | PASS |

Additional executable parity:

- `nix develop .#mainline -c dune runtest test/js_jsoo --force` — PASS,
  including `intercept_log parity` with all three result constructors.

## Carried behavioral evidence

The fixed log pipeline remains:

1. scoped minimum-level admission;
2. scoped attributes, then per-call attributes;
3. outermost-to-innermost intercept transforms;
4. the currently bound logger.

`Keep` passes the current record to the next stage, `Replace record` passes the
replacement, and `Drop` prevents every later transform and the sink. A filtered
record invokes no interceptor. `with_logger` inside and outside interception
selects the sink without bypassing the transform.

The carried suite proves composition traces, drop short-circuiting, fiber-local
sibling isolation, redaction after attributes, both logger-override nestings,
raising-transform defect capture, metric tenant enrichment, metric drop, and
jsoo parity. Existing `annotate_logs` and `with_minimum_log_level`
implementations remain unchanged and their suites pass unchanged.

## Review and red-team packets

Artifacts: `.scratch/research/dx/e20/review/` and
`.scratch/research/dx/e20/redteam/`.

- `redact-old.ml` versus `redact-new.ml`: delegating logger discipline versus a
  lexical `Replace` scrub independent of sink selection.
- `metric-old.ml` versus `metric-new.ml`: runtime-wide meter wrapper versus
  lexical tenant enrichment with `Replace`.
- `intercept-results.ml`: one readable callback using `Keep`, `Drop`, and
  `Replace` without helper machinery.
- The filter trap re-runs with `Keep` and still proves the callback is not
  invoked. The raising transform still becomes `Exit.Error (Cause.Die _)` and
  never reaches the sink.

The metric case remains honest and compelling; its kill condition does not
fire.

## E20 historical result

E20's standard-`option` design proved behavior but measured:

| Row | minor words/100k |
| --- | ---: |
| no intercept | 5,242,876 |
| `Some` identity | 6,291,447 |

It scored **6 / 7** and was correctly held because identity added ~10.49 minor
words per record. E20b was sealed to distinguish callback representation cost
from the remaining active-local cost.

## E20b watchlist result

Command:

```sh
taskset -c 0 nix develop -c dune exec \
  bench/runtime_watchlist/runtime_watchlist.exe -- \
  --samples 10 --filter overhead.eta.log
```

| Row | wall mean ± stddev | minor words | major words |
| --- | ---: | ---: | ---: |
| no intercept | 17,063,689 ± 187,713 ns | 5,242,876 | 67 |
| `Keep` identity | 11,671,758 ± 76,696 ns | 6,291,445 | 149 |
| `Replace record` | 11,580,610 ± 40,250 ns | 6,291,447 | 153 |

- **Wall gate:** PASS. `Keep` is 31.6% below baseline; this is not claimed as a
  speedup because activating fiber-local context changes backend lookup/GC
  behavior.
- **Keep zero-increment gate:** FAIL. Delta is +1,048,569 minor words/100k,
  ~10.48569 words/record.
- **Replace representation gate:** PASS relative to `Keep`. The complete 100k
  sample adds only 2 minor words, far below 3 words/record.
- **Replace end-to-end versus no intercept:** still includes the same active-
  local residual, ~10.48571 words/record.

E20b removes only two minor words from the entire sample versus E20. This shows
the old callback's boxed `Some` was not the per-record source in the optimized
binary. The residual comes from retrieving an active local through the current
Eio backend. Changing runtime-local representation or the denominator is outside
the follow-up's representation-only scope, so the raw result is preserved.

## Prediction scores

### E20 original — 6 / 7

Pipeline order, drop, shorthand parity, both use cases, jsoo, and defect capture
passed. The option identity allocation prediction failed.

### E20b amendment — 3.5 / 5

| Prediction | Result | Score |
| --- | --- | ---: |
| Carried behavior | PASS | 1 |
| Zero end-to-end `Keep` increment | FAIL | 0 |
| Replace cost | Representation PASS; stricter sealed denominator wording FAIL | 0.5 |
| No wall regression | PASS | 1 |
| Constructor readability | PASS | 1 |

## Footguns and final verdict

The same three traps remain disarmed by docs and tests: expecting interception
before minimum-level filtering, expecting inner-first transform order, and
expecting logger-override placement to bypass transformation. Undisclosed
footguns remain +0.

Verdict: **REPRESENTATION FIX PROVEN; PROMOTION HELD ON ACTIVE-LOCAL ALLOCATION**.
