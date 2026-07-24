# DX-E28 Report — `all` vs `map_par` T1 Audit

## Outcome

**E28 BLOCKED: C3 escalation — real production code passes an arbitrary stream
chunk to unbounded `Effect.all`; choosing whether to bound, merge, or accept
that behavior is a semantics decision.**

No runtime, `.mli`, API-guide, or law-registry file was changed. The assignment
permits the C1 documentation slice only if C1 wins; C3 requires design options
and a blocked handoff instead.

## V-DX-E28-01 — Origin answer

**Status: ACCEPTED evidence.** `all`'s current unbounded fan-out is an inherited
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

Current source confirms the split: `lib/eta/effect_concurrent.ml:52-85` forks
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

- The current `effect.mli` sentence (“Run effects concurrently”) does **not**
  catch the problem at review time.
- The current DX guide is worse: it recommends `Effect.all` for “dynamic
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

## Gates

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

## Recommendation

**HOLD and escalate (C3).** Do not promote the predicted C1 docs-only patch over
a known production violation. The orchestrator should choose Option A, B, or C;
Option C is the smallest route to the predicted differentiated contract but is
only honest if the JS stream caller is changed or explicitly bounded in the
same semantics decision.
