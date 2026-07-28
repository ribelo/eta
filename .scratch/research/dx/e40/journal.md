# DX-E40 Journal — sealed predictions

Sealed before any E40 product, test, API, guide, or law change. Base is
`142865c405c8c5c52f5821ba5bade8d78d18b0b5` on
`research/dx-e40-all-admission-split`. This prediction record is immutable after
its seal commit. The orchestrator journal was not consulted.

## Contract and implementation predictions

1. `Effect.all` can honestly reuse the existing fork-all shape beside
   `all_settled`: one indexed result array, one fork per prebuilt child, and the
   existing fail-fast aggregation/cancellation machinery. No `all_settled`
   worker-pool tangle is expected.
2. `Effect.all_bounded ~max_concurrent` will be the current `all` worker-pool
   engine under a required label, including construction-time rejection of zero
   and negative values.
3. Input-order collection, first-observed-failure cause propagation,
   cancellation, and finalizer completion will remain unchanged for `all`.
4. `map_par` remains default-eight and unchanged. No `all_settled_bounded` will
   be added; if requested by evidence, it will be deferred for lack of a named
   structural need.

## Deadlock-test predictions

- For a barrier of `N` children where each signals admission then waits for all
  `N` signals, `all_bounded ~max_concurrent:(N - 1)` will admit exactly `N - 1`,
  complete none, hit the deterministic timeout, cancel admitted children, run
  their finalizers, and leave no sleepers/fibers.
- The identical barrier under `all` will admit all `N`, complete in input order
  before the watchdog, and leave no sleepers/fibers.
- The former omitted-bound/default-eight tests will fail after the engine change
  until rewritten into that negative/positive pair.
- Existing fail-fast, cancellation, finalizer, and out-of-order/input-order
  witnesses will pass unchanged once bounded-only witnesses use the named API.
- `all_bounded ~max_concurrent:0` and every negative generated or fixed value
  will raise `Invalid_argument` while constructing the blueprint.

## Predicted omission-site classifications

Classification rule: **load-bearing** means the existing cap of eight is part of
the caller's intended resource/admission protocol; it must become
`all_bounded`. **safe-to-widen** means full admission preserves or strengthens
the caller's stated purpose. These are sealed predictions, to be checked in the
dossier census. Verification-only witnesses for the superseded default-eight
contract are safe-to-widen and must be adapted, not silently re-bounded.

| ID | Omission site | Prediction | Reason |
| --- | --- | --- | --- |
| O-001 | `lib/eta/pool.ml:102` | safe-to-widen | Fixed literal of four metric updates; effective admission was already four. |
| O-002 | `examples/all_health_checks.ml:11` | safe-to-widen | Fixed literal-derived list of three independent health checks. |
| O-003 | `examples/all_health_checks.ml:14` | safe-to-widen | Fixed literal-derived list of three independent health checks including one failure. |
| O-004 | `bench/runtime_concurrency/runtime_concurrency.ml:18` | safe-to-widen | The `all` benchmark should measure the public unbounded operation; rebounding would mislabel it. |
| O-005 | `bench/runtime_concurrency/runtime_concurrency.ml:19` | safe-to-widen | The heavy `all` benchmark should measure the public unbounded operation; rebounding would mislabel it. |
| O-006 | `bench/fixtures/typecheck/deep_bind/tp_m01.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-007 | `bench/fixtures/typecheck/deep_bind/tp_m02.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-008 | `bench/fixtures/typecheck/deep_bind/tp_m03.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-009 | `bench/fixtures/typecheck/deep_bind/tp_m04.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-010 | `bench/fixtures/typecheck/deep_bind/tp_m05.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-011 | `bench/fixtures/typecheck/deep_bind/tp_m06.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-012 | `bench/fixtures/typecheck/deep_bind/tp_m07.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-013 | `bench/fixtures/typecheck/deep_bind/tp_m08.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-014 | `bench/fixtures/typecheck/deep_bind/tp_m09.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-015 | `bench/fixtures/typecheck/deep_bind/tp_m10.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-016 | `bench/fixtures/typecheck/deep_bind/tp_m11.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-017 | `bench/fixtures/typecheck/deep_bind/tp_m12.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-018 | `bench/fixtures/typecheck/deep_bind/tp_m13.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-019 | `bench/fixtures/typecheck/deep_bind/tp_m14.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-020 | `bench/fixtures/typecheck/deep_bind/tp_m15.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-021 | `bench/fixtures/typecheck/deep_bind/tp_m16.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-022 | `bench/fixtures/typecheck/deep_bind/tp_m17.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-023 | `bench/fixtures/typecheck/deep_bind/tp_m18.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-024 | `bench/fixtures/typecheck/deep_bind/tp_m19.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-025 | `bench/fixtures/typecheck/deep_bind/tp_m20.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-026 | `bench/fixtures/typecheck/deep_bind/tp_m21.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-027 | `bench/fixtures/typecheck/deep_bind/tp_m22.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-028 | `bench/fixtures/typecheck/deep_bind/tp_m23.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-029 | `bench/fixtures/typecheck/deep_bind/tp_m24.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-030 | `bench/fixtures/typecheck/deep_bind/tp_m25.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-031 | `bench/fixtures/typecheck/deep_bind/tp_m26.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-032 | `bench/fixtures/typecheck/deep_bind/tp_m27.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-033 | `bench/fixtures/typecheck/deep_bind/tp_m28.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-034 | `bench/fixtures/typecheck/deep_bind/tp_m29.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-035 | `bench/fixtures/typecheck/deep_bind/tp_m30.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-036 | `bench/fixtures/typecheck/deep_bind/tp_m31.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-037 | `bench/fixtures/typecheck/deep_bind/tp_m32.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-038 | `bench/fixtures/typecheck/deep_bind/tp_m33.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-039 | `bench/fixtures/typecheck/deep_bind/tp_m34.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-040 | `bench/fixtures/typecheck/deep_bind/tp_m35.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-041 | `bench/fixtures/typecheck/deep_bind/tp_m36.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-042 | `bench/fixtures/typecheck/deep_bind/tp_m37.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-043 | `bench/fixtures/typecheck/deep_bind/tp_m38.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-044 | `bench/fixtures/typecheck/deep_bind/tp_m39.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-045 | `bench/fixtures/typecheck/deep_bind/tp_m40.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-046 | `bench/fixtures/typecheck/deep_bind/tp_m41.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-047 | `bench/fixtures/typecheck/deep_bind/tp_m42.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-048 | `bench/fixtures/typecheck/deep_bind/tp_m43.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-049 | `bench/fixtures/typecheck/deep_bind/tp_m44.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-050 | `bench/fixtures/typecheck/deep_bind/tp_m45.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-051 | `bench/fixtures/typecheck/deep_bind/tp_m46.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-052 | `bench/fixtures/typecheck/deep_bind/tp_m47.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-053 | `bench/fixtures/typecheck/deep_bind/tp_m48.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-054 | `bench/fixtures/typecheck/deep_bind/tp_m49.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |
| O-055 | `bench/fixtures/typecheck/deep_bind/tp_m50.ml:9` | safe-to-widen | Fixed literal of three independent, immediate effects; no admission bound is load-bearing. |

### Existing verification sites with more than eight or admission-sensitive children

| Site | Prediction | Reason |
| --- | --- | --- |
| `test/core_common/effect_common_suites.ml` fresh-counter 128-child witness | safe-to-widen | It proves uniqueness under concurrency, not a cap. |
| `test/core_common/effect_interruptible_shared.ml` 17-child witness | safe-to-widen | Finite independent children; it proves interrupt-mask identity. |
| `test/core_common/stress_common_suites.ml` 20-child pool witness | safe-to-widen | Pool size four remains the load-bearing bound. |
| `test/core_common/stress_common_suites.ml` 30-child semaphore witness | safe-to-widen | Semaphore permits remain the load-bearing bound. |
| `test/http/test_eta_http_h2_connection.ml` 10-stream witness | safe-to-widen | It tests concurrent streams and does not contract on eight. |
| `test/laws/law_properties.ml` 18-child queue transition witness | safe-to-widen | Immediate independent post-close observations. |
| cache/Pubsub fixed six-to-eight-child witnesses | safe-to-widen | Effective admission does not change. |
| current default-eight peak and omitted-bound barrier witnesses | safe-to-widen | They are executable claims for the superseded contract and will become the positive `all` half and negative `all_bounded` half. |

**Predicted total:** no omission site has a load-bearing hidden bound. Therefore
no omission will be silently rebound. Explicitly configured bounded witnesses
and consumers migrate to `all_bounded`; obsolete full-fan-out recipes become
plain `all` only where they are intentionally transformed into the positive
new-contract witness.

## Public census and footgun predictions

- Concurrency cluster: `+1` public value (`all_bounded`); `all` loses one optional
  parameter; all other public values are unchanged.
- Footgun delta: `-1/+0`. The hidden-eight liveness hazard disappears from
  `all`; the bounded coordination hazard remains but is review-visible in the
  required-name operation and its one-sentence caveat; no new footgun is added.
- Law registry: M114/M115/M117 and R127 move from `all` to `all_bounded`; M116
  (omission means eight) is replaced by the `all` admits-every-child guarantee;
  M118's explicit-length recipe is replaced by plain-`all` barrier completion.
  Admission/deadlock source spans and executable pointers will all move, with no
  orphan or stale default-eight claim.

## Gate predictions

All four required gates are expected to pass. The native suites should expose
only stale API calls and old admission assertions during migration. The
specified mainline JS build should require no behavior change because the
split is in core Eta and current JS target uses remain omission-only.

## Amendment predictions (sealed)

Sealed for Follow-up 1 before any follow-up product, test, API, guide, law, or
changelog change. Follow-up base is
`d31992f87d9cf5460850256fbf069b762ee13ed0`. This amendment may be scored and
annotated in the report, but neither this section nor the original predictions
above will be edited after the amendment seal commit.

### Gate and fail-fast predictions

1. One shared registration helper can create a start promise, register every
   input fiber with `await start` as its first action, and resolve the promise
   only after the registration loop finishes. `all` can opt into that helper
   through `par_run_forks`; `all_settled` can use the same helper directly,
   without changing `par`, bounded workers, or `map_par`.
2. On Eio, the wrapper's first action will suspend each newly registered fiber,
   returning control to the registration loop. A synchronous first-child typed
   failure therefore cannot prevent later fork registrations.
3. Once the gate opens, a synchronous first-child failure in `all` will trigger
   the existing group cancellation. Every input fiber will have been registered,
   the first body will run and fail, bodies that have not received a scheduler
   turn will not run, already-started siblings will be cancelled and awaited,
   and the group will exit with the first typed failure.
4. `all_settled` will register every input fiber before any body starts, then run
   every body after the gate opens. A synchronous first-child failure remains an
   `Error cause` value rather than failing the outer group; later child bodies
   run and their outcomes remain in input order.
5. Full admission is not scheduler preemption or fairness. After registration
   and gate release, an Eio child that never yields can monopolize the domain and
   prevent sibling bodies and the parent from progressing. A finite
   non-cooperative witness should show all registrations occur before its body
   monopolizes execution, while later bodies start only after it returns.

### Regression-test predictions

- A counted Eio backend will observe exactly `N` fork registrations for
  `all [sync fail; marked tail...]`, exactly one body mark, and
  `Exit.Error (Cause.Fail "boom")`. The current ungated implementation would
  observe one registration, so this discriminates the defect.
- The same counted backend will observe exactly `N` registrations and all `N`
  body marks for `all_settled [sync fail; marked tail...]`, with an outer
  successful list containing the first `Error` and later `Ok` values.
- A finite no-yield first body will still be preceded by all registrations, but
  its completion mark will precede the second body's start mark. This pins the
  documented admission-versus-scheduling boundary without hanging the suite.
- The existing barrier, order, fail-fast, cancellation, finalizer, and empty
  census witnesses should continue to pass. Focused Eio and law runs should fail
  before the gate only at the new `all` synchronous-failure registration check
  and pass after it.

### Predicted law-row changes

- M114 will sharpen from “admits every prebuilt child immediately” to “registers
  every prebuilt child fiber before any child body starts” and point to a named
  generated synchronous-first-failure property with an exact fork-registration
  count, exact body-start count, first typed failure, and empty fiber census.
- M115 will keep the coordination-group non-withholding claim and its generated
  barrier witness; its observation boundary remains cooperative rendezvous
  participants, while M114 carries the scheduler-independent registration proof.
- M126 will sharpen analogously for `all_settled` and point to a named generated
  synchronous-first-failure property proving exact registrations before body
  execution, all materialized outcomes, and an empty fiber census.
- The direct claim and QCheck-property counts should remain unchanged: rows and
  properties are strengthened in place rather than added or orphaned.

### Corrected footgun registration

The review correction is expected to score exact: the footgun delta is
**-1/+1**, not the original predicted **-1/+0**. Naming `all_bounded` removes the
hidden cap-eight coordination trap, while unbounded `all` introduces a visible
fan-out risk because a 10,000-element input registers approximately 10,000
fibers. The mli and API guide must reserve `all` for finite groups requiring full
admission, direct large or data-derived independent prebuilt lists to
`all_bounded`, and direct lazy collection mapping to `map_par`.
