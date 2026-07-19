# DX-E9 Report — `Syntax.Parallel` vs. `Syntax.Applicative`

## Recommendation

**HOLD for independent review numbers; implementation READY.**

Against the one-pager kill/promote gates:

| Gate | Criterion | This branch |
| --- | --- | --- |
| Promote | explicit ≥ 80% accuracy **and** materially above baseline | **Not self-awarded** — requires blinded review of `review/` |
| Kill | baseline already ≥ 80% (split is ceremony) | **Possible** — sealed baseline guess was 55%; if review lands ≥ 80% on `implicit.ml`, kill is honest |

Do not engineer for promote. The open-is-intent split is implemented, laws pass,
red-team passes, gates pass. Comprehension delta is the remaining decision input.

## Delivered surface

```ocaml
module Syntax : sig
  val ( let* ) : …
  val ( let+ ) : …
  val ( let@ ) : …
  module Parallel : sig
    val ( and* ) : …  (* Effect.par — concurrent, fail-fast sibling cancel *)
    val ( and+ ) : …
  end
  module Applicative : sig
    val ( and* ) : …  (* let* a = l in let+ b = r in (a, b) — nothing forked *)
    val ( and+ ) : …
  end
end
```

- `and*` / `and+` **removed** from the top-level `Syntax` module (no shim).
- Docs: `syntax.mli` (≤5-line semantics + "open exactly one"), `docs/api-dx.md`,
  `README.md`, `examples/README.md`.
- Call sites migrated to `Syntax.Parallel` (semantics preserved):
  `examples/background_lifecycle.ml`, `test/api_dx/api_dx_examples.ml` (runnable
  + snippet strings), `test/core_common/effect_common_suites.ml` syntax smoke.

## Gates

| Command | Attempts | Result |
| --- | ---: | --- |
| `nix develop -c dune build @install` | 1 | PASS |
| `nix develop -c dune runtest --force` | 1 | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | 1 | PASS |
| `nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo` | 1 | PASS (integer-overflow warnings pre-existing/unrelated) |

Focused syntax suite (Effect 55–61 on `test/core_eio/run.exe`): **7 / 7 OK**.

## Law-test evidence

| Obligation | Evidence | Status |
| --- | --- | --- |
| Parallel pair-order | `test_syntax_parallel_and_is_par` + cited `test_par_returns_both_successes` | Proven |
| Parallel fail-fast sibling cancel | `test_syntax_parallel_fail_fast_cancels_sibling` + cited `test_par_fail_fast_cancels_sibling` | Proven |
| Applicative strict L→R | `test_syntax_applicative_strict_left_to_right` (ordered side-effect log) | Proven |
| Applicative zero fork / right waits | `test_syntax_applicative_right_waits_for_left` (promise gate: right_started false until left settles) | Proven |
| Applicative fail-fast by sequencing | `test_syntax_applicative_fail_fast_skips_right` | Proven |
| Applicative left interrupt skips right | `test_syntax_applicative_interrupt_left_skips_right` (`effect_error_cause Cause.interrupt`) | Proven |
| Distinctness | `redteam/distinctness.ml` + suite contrast Parallel vs Applicative | Proven |

Note: in-flight host cancellation via `runtime_interrupt_effect` escapes as
Eio `Cancelled` through `B.run`; the interrupt law uses the typed interrupt
cause path already used elsewhere in the suite (`effect_error_cause Cause.interrupt`).

## Census / footgun actuals vs sealed predictions

| Measure | Sealed | Actual |
| --- | ---: | ---: |
| Syntax operator vals | 5 → 7 | **5 → 7** (base 3 + Parallel 2 + Applicative 2) |
| Syntax modules | 1 → 3 | **1 → 3** |
| Footguns | −1 concurrency / +0 double-open if documented | **−1** (always-open concurrent `and*` gone); double-open shadowing documented in `.mli` and `api-dx.md` (**+0** net new undoc footgun) |

§3.1 restatement: growth is justified only by a measured comprehension delta.
That measurement is the independent review; this report does not invent it.

## Red-team outcome

See `.scratch/research/dx/e9/redteam/VERDICT.md`.

- Old always-open `and*` invites order-sensitive DB writes that silently race
  (`implicit_race.ml` / `review/implicit-race.ml`).
- `open Syntax.Applicative` makes the sequential transfer correct
  (`explicit_sequential.ml` / `review/explicit-app.ml`).
- **PASS** as mechanical footgun demonstration; not a substitute for the
  comprehension gate.

## Review packet

Under `.scratch/research/dx/e9/review/`:

| File | Role |
| --- | --- |
| `implicit.ml` | Baseline always-open concurrent program |
| `explicit-par.ml` | Same program + `open Syntax.Parallel` |
| `explicit-app.ml` | Order-sensitive transfer + `open Syntax.Applicative` |
| `implicit-race.ml` | Wrong-under-old-shape twin |
| `MANIFEST.md`, `QUESTIONS.md` | Blinded prompts (fibers, sibling fate, order guarantees) |

Questions are designed so either side can win: if baseline answers are already
accurate, kill is supported.

## Deviations

1. README / examples README updated so package surface docs match the split
   (not only `api-dx.md`); keeps user-facing scan surfaces consistent.
2. Applicative interrupt law uses typed `Cause.interrupt` injection rather than
   `runtime_interrupt_effect` (host cancel escapes `B.run` as exception).
3. Comprehension accuracy is **not** estimated post-hoc from author intuition;
   sealed guesses remain; review decides promote/kill.

## Promote / hold / kill

- **Implementation:** complete, gates green, laws green, red-team pass.
- **Product decision:** **HOLD** until orchestrator blinded review scores
  baseline vs explicit. If baseline ≥ 80%, recommend **KILL**. If explicit ≥ 80%
  and materially above baseline, recommend **PROMOTE**. Mid outcomes → hold or
  redesign questions, not silent ship.

Confidence in implementation evidence: **High**.
Confidence in comprehension outcome: **Low** (untested by this executor; by design).
