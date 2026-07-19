# DX-E9 Journal — `Syntax.Parallel` vs. `Syntax.Applicative`

Branch: `research/dx-e9-syntax-parallel-applicative`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e9`
Phase: C (syntax & PPX) · Effort M · Risk med · live kill gate

## Predictions (sealed)

Sealed before documentation, implementation, test, or example edits. Wrong
predictions stay as evidence; this section will not be edited after its commit.

### Comprehension accuracy guesses

| Form | Guessed accuracy | Rationale |
| --- | ---: | --- |
| Baseline implicit (`let open Syntax in let* … and* …`) | **55%** | Callers who know OCaml `and` may read "independent binding" and miss concurrent fork + sibling cancel. Reviewers who know ZIO/async `par` may overfit and score high; mixed audience lands mid. |
| Explicit Parallel (`open Syntax` + `open Syntax.Parallel`) | **85%** | Module name states concurrency intent; still must recall fail-fast sibling cancel, so not free. |
| Explicit Applicative (order-sensitive program) | **80%** | "Applicative" is less self-explanatory than "Parallel" for OCaml readers; sequential left-then-right is recoverable from docs, but the name alone may not carry "nothing forked". |
| Implicit race twin (order-sensitive writes under old `and*`) | **40%** detect the race | Many readers will not notice interleaving risk without a prompt about effect order. |

Promote gate (from one-pager): explicit ≥ 80% **and** materially above baseline.
Kill gate: baseline already ≥ 80% → ceremony only.

My sealed forecast for the independent review: **promote is possible but not
assured**. Baseline may land 50–65%. If baseline ≥ 80%, kill is the honest
outcome and this journal will not argue against it.

### Likeliest reviewer misreadings — `Syntax.Parallel`

1. **`and*` means "independent values, sequential evaluation"** (Haskell
   do-notation / OCaml monadic `and` folklore) — misses fiber fork and sibling
   cancellation on failure.
2. **`Parallel` means CPU/domain parallelism** (`eta_par`) rather than eff
   concurrency on the current runtime substrate — over-reads the module name.

### Likeliest reviewer misreadings — `Syntax.Applicative`

1. **`Applicative` means "run both, combine successes, accumulate errors"**
   (validation applicative / `map2` folklore) rather than strict left-to-right
   sequencing with fail-fast by bind order.
2. **`and*` under Applicative still forks**, only "feels sequential" — confuses
   the new module with a soft rename of `par`.

### Census prediction

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Syntax operator vals | 5 (`let*`, `let+`, `let@`, `and*`, `and+`) | 7 (base 3 + Parallel 2 + Applicative 2) | **+2** |
| Syntax modules | 1 | 3 (`Syntax`, `Syntax.Parallel`, `Syntax.Applicative`) | **+2** |
| Footguns | always-open concurrent `and*` with no intent signal | "open exactly one of Parallel/Applicative" | **−1** (concurrency footgun) / **+0** net if double-open shadowing is documented |

### §3.1 growth justification (sealed, restated)

Operator growth 5 → 7 is accepted only if the extra vals buy an explicit
declaration of concurrent vs sequential product at the `open` site, measured by
comprehension delta. Growth without measured comprehension gain is ceremony and
fails the kill gate. The two new modules do not widen `Effect`; they re-home
existing product operators so the open is the intent signal (T2).

### Law-test plan prediction

| Obligation | Evidence |
| --- | --- |
| Parallel pair-order + fail-fast sibling cancel | Reuse/cite existing `Effect.par` tests (`test_par_returns_both_successes`, `test_par_fail_fast_cancels_sibling`); thin Syntax.Parallel smoke that `and*`/`and+` are `par`. |
| Applicative strict L→R | Ordered side-effect log under concurrent-looking `and*`. |
| Applicative zero fibers forked | Observable: right side-effect does not start before left settles. |
| Applicative fail-fast by sequencing | Left fails → right never runs. |
| Applicative left interrupt | In-flight left cancelled on interrupt; right not started. |
| Distinctness | Same program under each module: interleaved vs ordered log (`redteam/`). |

### Red-team prediction

Old always-open `Syntax` invites order-sensitive DB writes under `and*` that
silently race. New shape forces `open Syntax.Parallel` or `open
Syntax.Applicative`; the Applicative version is sequentially correct. Predict
the red-team **passes** as a mechanical demonstration; it does **not** by itself
prove the comprehension gate.

### Recommendation prediction (pre-evidence)

**HOLD pending independent review numbers.** Implementation should complete and
be reviewable either way. Self-recommendation after gates will stay provisional:
promote only if the blinded review shows a real delta; kill if baseline ≥ 80%.
