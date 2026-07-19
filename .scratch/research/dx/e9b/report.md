# DX-E9b Report — Honest `and*`: sequential everywhere

## Recommendation

**PROMOTE.**

Against the sealed decision rule (journal predictions):

| Gate | Criterion | Result |
| --- | --- | --- |
| Laws | sequential product laws executable and green | **PASS** (Effect 56–59) |
| Red-team (a) | order-sensitive transfer under `and*` correct by construction | **PASS** |
| Red-team (b) | concurrency-wanted + `and*` is perf-only residual | **PASS** |
| Red-team (c) | mli does not claim concurrent `and*` | **PASS** |
| Migration | 2 usage files preserve intent; justifications recorded | **PASS** (all sites → `Effect.par`) |
| Census | 5 vals / 1 module; footgun −1 / +0 perf | **PASS** |
| Build gates | four objective commands | **PASS** |

E9 held on module-switched `open`s (meaning must live at the operator/call
site). E9b places sequential meaning in `and*` and concurrent meaning in
`Effect.par` at the exact spot. Residual surprise is documented latency, not
silent order races.

## Delivered surface

```ocaml
(* lib/eta/syntax.ml *)
let ( and* ) left right =
  Effect.bind (fun a -> Effect.map (fun b -> (a, b)) right) left
let ( and+ ) left right =
  Effect.bind (fun a -> Effect.map (fun b -> (a, b)) right) left
```

- `and*`/`and+` stay top-level in `Syntax` (no `Parallel`/`Applicative` modules).
- Sequential product: left settles fully, then right; nothing forked; left
  failure skips right.
- `Effect.par` unchanged — explicit concurrent spelling.
- No compatibility shim for old par-`and*`.

## Gates

| Command | Attempts | Result |
| --- | ---: | --- |
| `nix develop -c dune build @install` | 1 | PASS |
| `nix develop -c dune runtest --force` | 1 | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | 1 | PASS |
| `nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo` | 1 | PASS |

Focused syntax laws on `test/core_eio/run.exe`: Effect 55–59 **OK**.

## Law-test evidence

| Obligation | Evidence | Status |
| --- | --- | --- |
| Strict L→R | `test_syntax_and_strict_left_to_right` | Proven |
| Right waits for left | `test_syntax_and_right_waits_for_left` | Proven |
| Fail-fast by sequencing | `test_syntax_and_fail_fast_skips_right` | Proven |
| Interrupt-left skips right | `test_syntax_and_interrupt_left_skips_right` | Proven |
| `Effect.par` concurrent laws | cite `test_par_returns_both_successes`, `test_par_fail_fast_cancels_sibling` | Proven (pre-existing) |

## Census / footgun actuals vs sealed predictions

| Measure | Sealed | Actual |
| --- | ---: | ---: |
| Syntax operator vals | 5 → 5 | **5** |
| Syntax modules | 1 → 1 | **1** |
| Footguns | −1 concurrency-misread / +0 perf-surprise | **−1 / +0** as sealed |

## Migration

All `and*` sites in the two usage files wanted concurrency under the old
contract; each is now `Effect.par` with a one-line journal justification.
Zero residual `and*` in those files. Snippet surface tests updated to expect
`Effect.par` and the new `let*` counts.

## Red-team outcome

See `.scratch/research/dx/e9b/redteam/VERDICT.md` and `output.txt`.

| Case | Outcome |
| --- | --- |
| (a) debit/credit transfer + `and*` | ordered log; correct by construction |
| (b) user/perms loads + `and*` (wanted concurrent) | both run, serialized; latency only |
| (c) mli concurrent claim | none; only `Effect.par` redirect |

## Review packet

Under `.scratch/research/dx/e9b/review/`:

| File | Role |
| --- | --- |
| `transfer.ml` | order-sensitive transfer with `and*` (safe shape) |
| `loads.ml` | concurrent loads with `Effect.par` |
| `MANIFEST.md`, `QUESTIONS.md` | blinded prompts |

Sealed expected answers are in the journal predictions section (not to be
edited). Orchestrator blinds and scores independently.

## Deviations

1. `examples/README.md` updated (adjacent to the example migration) so the
   example index does not still claim concurrent `and*`.
2. Red-team uses a local dune project under `.scratch/research/dx/e9b/redteam/`
   with `OCAMLPATH` to `_build/install/default/lib` (same pattern as e23).
3. Interrupt law uses typed `Cause.interrupt` injection (same approach as E9),
   not host `runtime_interrupt_effect` (escapes `B.run` as exception).

## Promote / hold / kill

- **Implementation:** complete, gates green, laws green, red-team pass.
- **Product decision:** **PROMOTE** under the sealed rule. Independent review
  of `review/` is confirmatory comprehension evidence, not a second semantics
  gate — the safety argument is executable (laws + red-team).

Confidence in implementation / safety evidence: **High**.
Confidence that residual perf surprise is acceptable: **High** (documented;
red-team (b) demonstrates it is not silent wrongness).
