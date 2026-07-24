# DX-E28 Sealed Predictions

This entry was written before any origin/history search or call-site census. It
is immutable after the sealing commit. Evidence, actuals, scoring, and the final
decision belong in `census.md` and `report.md`.

## Decision question

Do `Effect.all` and `Effect.map_par` represent one duplicated task, or two
distinct task shapes that need an explicit concurrency contract?

## Proof obligations

| ID | Question | Evidence that decides it | Risk before audit |
|---|---|---|---|
| P1 | Was `all`'s fork-per-effect behavior an intentional boundedness choice? | `git log -S`, blame, and the introducing/worker-pool commits | Medium |
| P2 | Do repository callers use two distinct task shapes? | Exhaustive classified census in the assignment's six trees | High |
| P3 | Is unbounded `all` a live production footgun? | Any real non-test large/dynamic `all` call site | High |
| P4 | Can one sentence/table make the wrong 10k-list choice review-visible? | Red-team the resulting contract | Medium |

## Hypothesis ledger at seal time

| Candidate | Strongest case | Win condition | Falsifier | Predicted status |
|---|---|---|---|---|
| C1 — Differentiate | Literal ready effects and mapped collections are visibly different construction tasks and need different fan-out policies. | Census shows small ready-effect `all` sites and collection-oriented `map_par` sites, with no real large/dynamic `all`. | The shapes do not separate, or real code feeds arbitrary large lists to `all`. | ACCEPT |
| C2 — Merge | `all xs` is extensionally `map_par Fun.id xs`, so one operation may satisfy T1 with an explicit cap. | Call sites show no meaningful task-shape distinction. | Both predicted shapes occur naturally and are easy to state. | REJECT |
| C3 — Escalate | Unbounded fork-per-effect can be a fork bomb if real code feeds it arbitrary collections. | At least one large/dynamic `all` in real non-test code. | No such real call site exists. | REJECT |

## Quantitative predictions

I predict **170 total call sites** after excluding definitions, prose, generated
build output, and comments, classified as follows:

| Class | Predicted count | Predicted share |
|---|---:|---:|
| (a) small literal list (at most five) | 43 | 25% |
| (b) collection mapping | 122 | 72% |
| (c) large/dynamic list into `all` | 0 | 0% |
| (d) two-to-three literal inputs into `map_par` | 5 | 3% |
| **Total** | **170** | **100%** |

Boundary prediction: awkward test helpers may construct a list in a variable
before passing it to `all`, but inspection will show a fixed small cardinality;
those belong to (a), not (c). I predict no category-(c) call in real code and no
more than two category-(c) test-only stress/protocol cases if strict syntax
rather than semantic cardinality forces them to be recorded separately.

## Origin, decision, and deltas

- **Origin answer:** `all` predates the worker-pool optimization. Its
  fork-per-effect implementation was inherited rather than introduced as an
  explicit public promise of unbounded fan-out. `map_par` inherited the later
  cap-eight worker pool deliberately.
- **Decision:** C1 — differentiate. Keep runtime behavior unchanged; document
  `all` as one fiber per effect for a known small handful and `map_par` as the
  bounded collection-mapping form (default eight).
- **Census delta:** public values 2 -> 2; implementation engines 2 -> 2;
  ambiguous task recommendations 2 -> 0; explicitly differentiated task shapes
  0 -> 2.
- **Footgun delta:** -1 existing ambiguity, +0 new footguns. The unbounded engine
  remains, but the mli and one-row-per-task concurrency table should make an
  arbitrary/10k input list visibly the wrong use of `all` during review.

## What would overturn the prediction

- Any real non-test category-(c) site selects C3 regardless of the predicted C1.
- A census dominated by interchangeably shaped calls, especially literal
  `map_par Fun.id` and mapped dynamic lists assembled for `all`, gives C2 a fair
  path to win.
- History showing an explicit accepted contract that `all` is the dynamic-list
  primitive weakens C1 and must be reconciled rather than ignored.
