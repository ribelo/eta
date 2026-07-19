# DX-E9b Journal — Honest `and*`: sequential everywhere

Branch: `research/dx-e9b-honest-and-star`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e9b`
Phase: C (syntax & PPX) · Effort S–M · Risk low–med
Evidence IDs: `V-DX-E9B-*` (orchestrator log); this journal is the branch record

## Predictions (sealed)

Sealed before documentation, implementation, test, or example edits. Wrong
predictions stay as evidence; this section will not be edited after its commit.

### Contract prediction

Top-level `Syntax.(and*)` / `Syntax.(and+)` become sequential product:

```ocaml
Effect.bind (fun a -> Effect.map (fun b -> (a, b)) right) left
```

- Left settles fully, then right runs; nothing forked.
- Left failure skips right (fail-fast by sequencing).
- `Effect.par` stays the only concurrent product spelling at the call site.
- No `Syntax.Parallel` / `Syntax.Applicative` modules (E9 split is dead).
- No compatibility shim for the old par-`and*`.

### Pre-registered decision rule (restated for this branch)

Promote when all of the following hold:

1. Sequential product laws are executable and green (L→R order, right waits,
   fail-fast skips right, left interrupt skips right).
2. Red-team shows the old invited bug (order-sensitive transfer under `and*`)
   is **observably sequential / correct by construction**, and the residual
   surprise for a concurrency-wanting program is **perf-only** (serialized,
   both sides run on success, no cancel-on-sibling-fail).
3. Docs no longer claim or imply concurrent `and*`.
4. The two usage files preserve intended runtime meaning per site (concurrent
   sites spelled `Effect.par`; sequential sites may keep `and*`).
5. Gates pass; census stays 5 operator vals / 1 Syntax module.

Hold if laws/red-team/docs are incomplete or a call-site intent is ambiguous
without a one-line journal justification.

Kill only if sequential `and*` reintroduces a worse footgun than concurrent
`and*` (for example: silent wrongness that is not merely latency) **or** if
making concurrency explicit at the call site is shown to be unusable for the
documented user stories. E9's hold (V-DX-E9-002) already rejected
module-switched `open`s as the intent signal; this experiment is the
call-site-honest alternative, not a re-run of E9.

### Expected independent-review answers (QUESTIONS.md)

| # | Question | Predicted correct answer |
| --- | --- | --- |
| 1 | How many fibers fork in `transfer.ml`? | **Zero** additional product fibers; `and*` sequences. (Body may still run on the ambient fiber.) |
| 2 | If debit fails, does credit run? | **No** — left failure skips right by sequencing. |
| 3 | Is effect order guaranteed in transfer? | **Yes** — strict left-to-right. |
| 4 | What does `Effect.par` do in `loads.ml`? | Forks both loads as siblings; fail-fast cancels the other on first failure. |
| 5 | Where would you look for concurrency in loads? | The **`Effect.par` call site** (not an `open`, not `and*`). |

### Migration split prediction (2 files)

All current `and*` sites under the old contract mean concurrent product
(`Effect.par`). Judgment: every site **wanted concurrency** (independent loads
/ independent parses; names and docs say concurrent). Predicted split:

| Site | File | Keep concurrent? | Predicted spelling | One-line justification (pre-edit) |
| --- | --- | --- | --- | --- |
| load left/right users | `examples/background_lifecycle.ml` | Yes | `Effect.par` | Independent named loads; old `and*` was par; no order dependence. |
| scoped left/right load | `test/api_dx/api_dx_examples.ml` `scoped_resource_proposed` | Yes | `Effect.par` | Independent DB loads inside scope; concurrency was the proposed DX. |
| parallel_business ids | `test/api_dx/api_dx_examples.ml` `parallel_business_proposed` | Yes | `Effect.par` | Function name and independent pure parses; concurrent product intent. |
| background left/right | `test/api_dx/api_dx_examples.ml` `background_proposed` | Yes | `Effect.par` | Independent user loads after wait; same as example lifecycle. |
| scoped snippet string | `api_dx_examples.ml` scoped_resource proposed code | Yes | `Effect.par` | Snippet must match runnable proposed shape. |
| background snippet string | `api_dx_examples.ml` background proposed code | Yes | `Effect.par` | Snippet must match runnable proposed shape. |

No site predicted to remain sequential `and*` after migration (zero residual
`and*` call sites in the two files). Sequential `and*` still ships for future
order-sensitive products and for the red-team/review transfer program.

### Census / footgun prediction

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Syntax operator vals | 5 | 5 | **0** |
| Syntax modules | 1 | 1 | **0** |
| Footguns | concurrent `and*` looks sequential | sequential `and*` is honest; concurrent only via `Effect.par` | **−1** concurrency-misread footgun; **+0** residual = documented **perf surprise** if someone wanted races but wrote `and*` |

### Law-test plan prediction

| Obligation | Evidence |
| --- | --- |
| Strict L→R | Ordered side-effect log under top-level `Syntax.and*` |
| Right waits for left | Promise gate: `right_started` false until left settles |
| Fail-fast by sequencing | Left fails → right never runs |
| Interrupt-left skips right | Left interrupt cause → right never runs |
| `Effect.par` laws | Cite existing `test_par_returns_both_successes`, `test_par_fail_fast_cancels_sibling` (no Parallel module smoke) |

### Red-team prediction

| Case | Predicted verdict |
| --- | --- |
| (a) Order-sensitive debit/credit under `and*` | **PASS** — ordered log; correct by construction |
| (b) Concurrency-wanted program written with `and*` | **PASS as perf-only** — both effects run in order; no sibling cancel; cost is latency |
| (c) Docs claim check | **PASS** — no mli implication that `and*` is concurrent |

### Two likeliest reviewer misreadings

1. **"`and*` still means concurrent product"** — muscle memory from pre-E9b Eta
   (or ZIO/async `parZip` folklore) even after the mli says sequential; reader
   scores transfer as racing fibers.
2. **"`Effect.par` is only for CPU/`eta_par` domains"** — confuses eff
   concurrency on the runtime substrate with domain parallelism; looks past
   the call-site spelling in `loads.ml`.

### Recommendation prediction (pre-evidence)

**PROMOTE** if gates + laws + red-team + migration justifications land as
sealed. This is a semantics swap with a safety argument (E9 hold: meaning at
the operator/call site), not a comprehension ceremony. Residual risk is
documented latency surprise, not silent wrongness for order-sensitive code.

## Implementation follow-up (post-seal; predictions section untouched)

_Pending — filled after the sealed predictions commit._
