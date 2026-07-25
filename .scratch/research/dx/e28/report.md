# DX-E28 Report — `all` vs `map_par` T1 Audit

## Outcome

**E28 READY FOR REVIEW.** Follow-up 1 resolved the C3 escalation with orchestrator
decision V-DX-E28-002: Option A, unified admission. `Effect.all` and `map_par`
now share default-eight bounded worker admission and remain differentiated by
input shape and static introspection.

The original audit and escalation below remain the evidence that led to that
decision. The implementation verdict and final gates are recorded in the
Follow-up 1 section.

## V-DX-E28-01 — Origin answer

**Status: ACCEPTED evidence.** `all`'s audit-time unbounded fan-out was an inherited
implementation path, not a deliberate later contract differentiating it from
the collection mapper.

Evidence chain:

| Commit | Evidence |
|---|---|
| `f19e4b239f74a14a53980a076da73e8f4ad102c4` (2026-05-19, `feat: par / all / for_each_par concurrent combinators`) | Introduced both operations. The commit body says “a single `par_collect` helper drives all three”; both `all` and `for_each_par` therefore began as fork-per-element operations. |
| `354c272216bed7daa8af4e698b377b9a0c02b818` (2026-05-26) | Performance commit capped only `for_each_par`: `let workers = min n 8`, with the subject explicitly citing cache locality. It did not modify `all`. |
| `e2eafb3f06df775d2d83d0806628efdc03e41d4f` (2026-05-30) | File decomposition preserved `all_eval -> par_collect` and the worker-pool mapper path. |
| `7843dd1a2a93d43d569a7f6d1c259cb072df6429` (2026-07-18, DX-E24) | Renamed/absorbed `for_each_par` into `map_par`, retaining default eight and the worker pool; `all` remained on `par_collect`. |
| `c9809d3ed2e750c6cd9d8709587b94bf6cb408f3` (2026-07-21) | Added effect introspection names/footprints without changing either concurrency engine. |

Source at the audit commit confirmed the split: `lib/eta/effect_concurrent.ml:52-85` forked
every item in `par_run_forks`; `all_eval` reaches it through `par_collect` at
lines 269-274. `map_par_workers` creates only the selected worker count at lines
301-318, and `map_par` defaults `max_concurrent` to eight at lines 320-327.

The original fork-per-item mechanism was deliberate as an implementation of
both APIs. What history does **not** support is a deliberate product decision
that `all` should remain unbounded after only the mapper received the cap.

## V-DX-E28-02 — Census

**Status: ACCEPTED evidence.** The primary artifact is `census.md`, which lists
all 198 compiled call sites and the classification rule.

| Class | Actual | Share |
|---|---:|---:|
| (a) small literal list into `all` | 85 | 42.9% |
| (b) collection mapping with `map_par` | 31 | 15.7% |
| (c) large/dynamic list into `all` | 19 | 9.6% |
| (d) 2–3 literal inputs into `map_par` | 63 | 31.8% |
| **Total** | **198** | **100%** |

The large (a)/(d) fixture counts include 50 mechanically generated typecheck
files, each containing both shapes. They remain in the raw totals because the
assignment requires every call site, but they are one repeated workload pattern
rather than 100 independent adoption decisions.

The decisive counterexample is production code in
`lib/js_stream/eta_js_stream.ml:76`:

```ocaml
Eta_js.Effect.map (fun ys -> Chunk ys)
  (Eta_js.Effect.all (List.map f xs))
```

`xs` is a stream chunk with no cardinality constraint in this operation's
contract. That is a dynamic collection mapped through `all`, precisely the C3
trigger. Test and benchmark sites also prove that `all` is intentionally run at
6, 8, 10, 17, 20, 30, 64, and 128 children; these are evidence that merely
calling current usage “always a handful” would be false.

## V-DX-E28-03 — Hypothesis ledger

| Candidate | Strongest supporting evidence | Strongest counterevidence | Status |
|---|---|---|---|
| C1 — Differentiate | Most product/example `all` calls are small literals, and `map_par` already owns a tested bound. A crisp task-shape rule is teachable. | The production JS stream call violates the proposed “known handful only” contract today. Shipping only prose would document existing library code as wrong without resolving its semantics. | **BLOCKED by C3 trigger**, not rejected as a future option. |
| C2 — Merge | Extensionally, `all effects` can be expressed as mapping identity; one operation would satisfy T1 and make bounded collection execution the default. | 85 small `all` sites and 63 literal `map_par` sites show both spellings are entrenched, while deletion requires a conscious replacement rule for ready effects and explicit full fan-out. | **ACTIVE design option**, unselected. |
| C3 — Escalate | A real non-test dynamic `all` exists, and history gives no intentional contract for the divergence. | Host stream chunks may usually be modest, but that is neither enforced nor documented and therefore cannot discharge the trigger. | **ACCEPTED.** |

## V-DX-E28-04 — Design options for the orchestrator

### Option A — Bound `all` semantically

Change `all` to use a worker count (for example default eight) rather than one
fiber per effect. This closes the production footgun without requiring callers
to construct a mapper. It is a runtime semantics change: start timing, peak
concurrency, stress behavior, and any test that expects all children to become
simultaneously live must be revalidated. It also reduces the behavioral reason
to retain both names unless `all` is explicitly “ready effects” and `map_par`
is “lazy mapper construction.”

Decision needed: fixed default versus a new explicit bound, and whether mapper
laziness versus preconstructed effects is enough differentiation for T1.

### Option B — Merge into `map_par`

Delete `all`. Dynamic callers use bounded `map_par Fun.id effects`; callers that
truly require full fan-out spell an explicit `~max_concurrent:(List.length
effects)`. This makes the dangerous choice review-visible and leaves one worker
engine. It changes a broad public surface (104 calls in this repository) and
needs an explicit decision about whether full fan-out remains supported as an
ordinary recipe.

Decision needed: whether ready-effect collection remains a distinct user task
worth a named operation.

### Option C — Accept unbounded `all`, differentiate, and repair callers

Keep one-fiber-per-effect semantics; state it in `effect.mli`; reserve `all` for
a known small handful; use bounded `map_par` for arbitrary collections. The JS
stream implementation must then move from `all (List.map f xs)` to `map_par f
xs` (or enforce a small chunk bound). That runtime code change is outside this
audit assignment and would require native/JS behavioral verification. The API
guide can then provide exactly one recommended form per task shape.

Decision needed: whether unbounded full fan-out is valuable enough to retain as
a public sharp edge, and whether the JS stream operation should become bounded.

## V-DX-E28-05 — Prediction scoring and deltas

| Sealed prediction | Actual | Score |
|---|---|---|
| 170 total sites | 198 | Miss |
| (a) 43 / 25% | 85 / 42.9% | Miss |
| (b) 122 / 72% | 31 / 15.7% | Miss |
| (c) 0 / 0% | 19 / 9.6% | Miss |
| (d) 5 / 3% | 63 / 31.8% | Miss; 50 are generated fixture repetitions |
| No real category-(c) site | One in `lib/js_stream/eta_js_stream.ml` | Decisive miss |
| `all` predates the cap-eight mapper optimization | Confirmed by commits | Hit |
| C1 wins | C3 is mandatory | Miss |
| Public vals 2 -> 2; task ambiguity 2 -> 0 | No product contract changed while blocked | Not realized |
| Footguns -1 / +0 | At least one live production dynamic-`all` footgun remains; no new one added by this audit | Miss on removal, hit on additions |

Actual census delta is **0** because an audit does not change call sites. Actual
footgun delta is **-0/+0**; the audit identified rather than repaired the
production risk.

## V-DX-E28-06 — Red-team pass

Wrong-choice probe:

```ocaml
Effect.all (List.init 10_000 fetch)
```

- The audit-time `effect.mli` sentence (“Run effects concurrently”) did **not**
  catch the problem at review time.
- The audit-time DX guide was worse: it recommended `Effect.all` for “dynamic
  homogeneous lists,” so it positively supports the wrong choice.
- The proposed C1 wording (“one fiber per effect; only a known small handful;
  arbitrary collections use bounded `map_par`”) would catch the 10k case and the
  existing JS stream case. That is crisp, but the latter is why the wording
  cannot honestly be shipped without a semantics/caller decision.
- Option B also catches it mechanically: ordinary `map_par Fun.id` defaults to
  eight, while full fan-out requires an explicit length-derived cap.
- Option A catches it at runtime through the bound, though the call site alone
  communicates less intent unless documentation still distinguishes task
  shapes.

## Audit-round gates

All exact assignment gates passed on the blocked research branch:

| Command | Result |
|---|---|
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |

These gates validate the unchanged product tree plus committed research
artifacts. There are no `.mli` edits, so no law-bearing prose or `LAWS.md` row
was added. The JS finding is design evidence only; no JS/runtime behavior was
changed.

## Audit-round recommendation (superseded)

**HOLD and escalate (C3).** Do not promote the predicted C1 docs-only patch over
a known production violation. The orchestrator should choose Option A, B, or C;
Option C is the smallest route to the predicted differentiated contract but is
only honest if the JS stream caller is changed or explicitly bounded in the
same semantics decision.

## Follow-up 1 — Unified admission implementation

### V-DX-E28-07 — Implemented contract

**Status: ACCEPTED.** `Effect.all` now has this public shape:

```ocaml
val all :
  ?max_concurrent:int -> ('a, 'err) t list -> ('a list, 'err) t
```

`all` and `map_par` call one indexed `collect_workers` scheduler. Both omit to
eight workers, reject nonpositive bounds during blueprint construction, collect
in input order, and retain fail-fast cleanup. The surfaces remain distinct:

- `all` receives prebuilt effects and preserves `concat_names` plus the unioned
  child capability footprint in static introspection;
- `map_par` receives a function and collection and does not force the mapper at
  blueprint construction.

`lib/js_stream/eta_js_stream.ml` now expresses its actual task directly as
`Eta_js.Effect.map_par f xs`, closing the production eta-expansion bypass found
by the census.

### V-DX-E28-08 — Executable evidence

| Obligation | Evidence |
|---|---|
| Default peak eight | `all default cap is eight` blocks nine children on the test clock and observes exactly eight admitted. |
| Explicit full fan-out | `all explicit bound admits full rendezvous` uses nine participants that cannot complete until all nine are live, with `~max_concurrent:(List.length effects)` and a deterministic watchdog. |
| Generated full fan-out | QCheck `all explicit length bound admits every generated rendezvous participant` covers nonempty sizes 1–12 behind a virtual-clock watchdog. |
| All-workers-blocked hazard | `all omitted bound stalls when every worker awaits unadmitted` observes exactly eight live participants, advances the test clock without completing or admitting the ninth, then cancels and proves child/sleeper cleanup. QCheck `all omitted bound cannot progress when every admitted worker awaits an unadmitted participant` additionally records an exact empty fiber census. |
| Configured/effective bound | QCheck `all never exceeds max_concurrent and reaches the bound when children suffice`. |
| Omission means eight | QCheck `all omission admits at most eight children and reaches eight when inputs suffice`. |
| Invalid construction | Alcotest `all rejects nonpositive max`; QCheck `all rejects every generated nonpositive max_concurrent at construction`. |
| Input order | Existing QCheck `all collects results in input order after reverse observable completion` and shared runtime test `all preserves delayed input order`. |
| Bounded fail-fast/finalizers | QCheck `all first observed failure cancels siblings and awaits their finalizers` now includes unadmitted tails; `all bounded fail-fast never admits tail` proves the admitted sibling finalizes and two tail effects never start. Existing cleanup baselines also pass. |
| Empty input | Existing `all empty returns empty list` passes unchanged. |
| Introspection | `audit declared leaves and preserve union` now includes five named `all` children discriminating clock, log, metric, resource, concurrency, and background footprints; describe snapshots remain green. |
| JS stream behavior | Mainline `stream_map_effect_preserves_order_and_caps_admission` proves ordered values, exact peak eight, exact mapper count, and cleanup. `stream_map_effect_invokes_mapper_only_as_workers_admit` discriminates the migration by observing exactly eight mapper invocations while the first wave is blocked; the former `all (List.map f xs)` shape would observe twelve. |

The law registry adds M114–M118 plus R127, R129, and R130, updates all shifted
exact `effect.mli` spans and shared-suite pointers, and records 69 named QCheck
properties.

### V-DX-E28-09 — Semantics-change ledger

These pre-existing tests execute more than eight `all` children and therefore
change from fork-per-list to cap-eight waves by design. None requires a barrier,
so all pass without an explicit override.

| Existing executable | Children | Justification for bounded behavior |
|---|---:|---|
| `fresh is unique under concurrency` — `test/core_common/effect_common_suites.ml` | 128 | It proves uniqueness under concurrent pulls, not simultaneous admission; waves retain the observation. |
| `interruptible outside a mask is identity` — `test/core_common/effect_interruptible_shared.ml` | 17 | Every child is finite and independent; the test observes values and mask identity, not full fan-out. |
| `pool no resource leak` — `test/core_common/stress_common_suites.ml` | 20 | Pool admission is already bounded to four; cap-eight upstream admission preserves stress and cleanup. |
| `semaphore permit accounting` — `test/core_common/stress_common_suites.ml` | 30 | The semaphore already admits five and each worker terminates; waves preserve permit accounting. |
| `h2 connection concurrent streams` — `test/http/test_eta_http_h2_connection.ml` | 10 | Requests are independent; default-eight admission remains a valid concurrent-stream test. |
| `Queue combined and view close or shutdown effect wrappers equal direct transitions` — `test/laws/law_properties.ml` | 18 | Every post-close check is immediate and independent; waves preserve exact transition observations. |

Existing six-child Pubsub receive and fresh-counter sites and the eight-waiter
cache site do **not** change effective admission: their input length is at or
below the new default. The runtime concurrency benchmark's 64-child `all` cases
also become cap-eight by default; that is benchmark semantics rather than a test
contract and now directly measures the unified policy.

### V-DX-E28-10 — Red-team

1. **10k eta-expansion:**

   ```ocaml
   Effect.all (List.map f xs)
   ```

   With 10,000 inputs, QCheck and the nine-child peak test establish that
   omission admits at most eight. Rewriting `map_par f xs` as prebuilt effects
   no longer bypasses admission. The DX table still recommends `map_par` for the
   function-plus-collection shape, while runtime safety is identical.

2. **Interdependent barrier over eight:** omission admits eight children. When
   all eight wait for the ninth, every admitted worker is blocked and no worker
   can admit the ninth. The bounded-barrier test observes exactly that condition:
   advancing the clock completes no participant and admits no more work, while
   cancellation still leaves clean child, sleeper, and fiber censuses. The
   positive nine-way rendezvous proves the adjacent explicit-length recipe.

### V-DX-E28-12 — Follow-up 2 review rework

- **W1:** the mli and DX guide now state only the all-workers-blocked hazard.
  R127 matches that claim and points directly at the discriminating test-clock
  and exact-census evidence rather than inferring deadlock from admission peaks.
- **W2:** the orphaned `par_collect` helper was deleted and the module header now
  advertises the shared `collect_workers` admission engine.
- **W3:** the JS migration test observes eight mapper calls while eight effects
  are blocked, then releases them and observes all twelve ordered results. This
  fails under the former eager `all (List.map f xs)` construction.
- **W4:** both fixed and generated full-fan-out rendezvous tests have watchdogs,
  converting admission regressions into focused timeout failures.

All four sealed Follow-up 2 micro-predictions hit their exact expected
observations.

### V-DX-E28-11 — Prediction scoring

#### Audit-round sealed predictions

The original scoring in V-DX-E28-05 remains unchanged: origin was a hit, while
the census totals, absence of a production footgun, and predicted C1 decision
were misses. That miss correctly activated C3 and led to the orchestrator's
semantics decision rather than a misleading docs-only patch.

#### Follow-up 1 sealed micro-predictions

| Prediction | Actual | Score |
|---|---|---|
| Default peak exactly 8 | Exact in shared test and generated law | Hit |
| Nine-way explicit rendezvous completes | Exact | Hit |
| Input order preserved | Existing and generated laws pass | Hit |
| Fail-fast/cancellation/finalizer parity | Existing laws and baselines pass | Hit |
| Empty succeeds; nonpositive bounds reject at construction | Exact | Hit |
| Static names/footprints and describe shape preserved | Exact | Hit |
| `map_par` mapper remains construction-lazy | Existing mapper-defect tests plus JS lazy-mapper assertion pass | Hit |
| JS mapping preserves order/failure model and caps peak | Ordered cap-eight JS test and full JS suites pass | Hit |
| At most two tests need explicit fan-out | No pre-existing test needed migration; only the new rendezvous uses it | Hit |
| Only production JS stream caller needs migration | Exact repository result | Hit |

### Final gates

| Command | Result |
|---|---|
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo test/js_stream test/http_js --force` | PASS (existing integer-overflow warnings only) |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_stream --force` | PASS after the final lazy-mapper assertion |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo test/js_stream test/http_js test/laws --force` | PASS after Follow-up 2 |

### Final recommendation

**PROMOTE unified admission.** The implementation closes the live production
footgun, gives both collection forms one admission policy, keeps one obvious
form per input shape, preserves `all`'s introspection advantage, and has native
plus js_of_ocaml evidence for the changed behavior.
