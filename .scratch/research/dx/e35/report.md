# DX-E35 report — stack-safety probe of the Eta interpreter

Date: 2026-07-26. Branch: `research/dx-e35-stack-safety`.
Experiment record: `journal.md` (sealed predictions, immutable),
`probe/` (boundary corpus + raw evidence), this file (verdict and scoring).

## Question

Audit claim under test (`.scratch/research/eop-audit-2026-07-26.md` §4.1):
the interpreter descends recursively through `Map`/`Bind` with no trampoline
and no explicit continuation stack, and `concat` builds statically nested
binds via `List.fold_left` — therefore stack safety is unestablished.

Decision rule (pre-registered in the assignment): if every corpus case passes
at 1M on both native and js_of_ocaml/Node, the interpreter stays untouched
and the corpus becomes regression tests; any failure on any substrate
triggers the trampolined-interpreter phase.

## Probe numbers

Corpus: `probe/` (standalone dune project, six cases, fresh process per
run, 300 s timeout, semantic verification per run — exact value, exact
handler count, or exact leaf count/order). Full tables and environment:
`probe/RESULTS.md`; raw logs: `probe/RESULTS.raw.txt`,
`probe/RESULTS.ox.raw.txt`, `probe/CALIBRATE.raw.txt`, `probe/BEYOND.raw.txt`.

| Case (depths 10k / 100k / 1M) | Native OCaml 5.4.1 | Native OxCaml 5.2.0+ox | jsoo/Node 24 |
| --- | --- | --- | --- |
| dynamic bind chain | PASS all | PASS all | PASS all |
| static deep map nesting | PASS all | PASS all | PASS all |
| concat of prebuilt effects | PASS all | PASS all | PASS all |
| deep bind_error recovery | PASS all | PASS all | PASS all |
| left-deep Cause.Sequential + failures | PASS all | PASS all | PASS all |
| left-deep Cause.Concurrent + failures | PASS all | PASS all | PASS all |

Beyond-matrix headroom (mainline): dynamic bind 10M PASS both substrates;
static map / bind_error / cause tree 3M PASS both substrates. No failure
point was reached anywhere, so no boundary bisection was applicable and no
failure mode (stack_overflow, segfault, OOM, hang) was ever observed.

## Verdict

**All pass at 1M on both substrates → Phase 2 is not triggered.** The
interpreter is untouched (no commit in this experiment modifies `lib/`; the
branch diff contains only `.scratch/research/dx/e35/` and the two promoted
test files). The corpus is promoted to bounded regression tests
(`test/eta/test_eta_effect_core.ml`, `test/js_jsoo/test_eta_jsoo.ml`).

## Why the recursive interpreter survives (T10: one semantics, two substrates)

The audit's code reading is accurate — `eval` in `lib/eta/effect_core.ml`
is non-tail recursion for `Map`, non-tail descent into `inner` for `Bind`,
and `concat` produces a left-deep bind chain. What the audit could not see
from code alone is that both shipped substrates absorb that recursion:

- **Native (5.4.1 and OxCaml 5.2.0+ox):** OCaml 5 runs OCaml code on
  heap-allocated, dynamically growable fiber stacks. The 8 MiB `ulimit -s`
  C stack is not the bounding resource; at these depths stack exhaustion
  becomes a heap question. Calibration (`probe_calibrate`): raw non-tail
  recursion passes at 1M natively.
- **js_of_ocaml/Node:** the project compiles JS with `--effects=cps`, which
  trampolines CPS-transformed calls. Evidence in the generated
  `probe_jsoo.bc.js`: `caml_trampoline_cps_call` ×4640,
  `caml_exact_trampoline_cps_call` ×1112, `caml_trampoline_return` ×461,
  `caml_stack_check_depth` ×461. Eta's `eval` is CPS-transformed because it
  transitively reaches effect-performing `Custom` leaves, so its recursion
  rides the trampoline and never grows the JS call stack. Calibration
  control: raw non-effectful OCaml recursion compiled by the same jsoo is
  direct-style and dies at ~10k (plain JS recursion dies at 12,513) — so the
  1M–3M Eta passes are real depth, not a measurement artifact.

Honest boundary of the guarantee: it is **substrate-mediated, not
intrinsic**. Bytecode, a non-CPS js_of_ocaml build, or any substrate with
bounded OCaml stacks would reopen the question, and native survival at
extreme depths is ultimately memory-bound. That is exactly why the
promoted regression tests (100k–1M native, 10k–100k jsoo) run in the normal
gates on both substrates: if the guarantee ever stops being true, the tests
fail with the case name, not a truncated result.

## Phase 2 sections — not applicable

- **Design note / parity evidence / red-team:** no rewrite happened, so
  there is no loop/stack design to document and no adversarial rewrite
  surface to attack. Parity of the untouched interpreter is established by
  the full existing suite (gates below) plus the promoted corpus.
- **Perf guard:** no code changed, so no benchmark delta exists to guard;
  the `bench/runtime_watchlist` run prescribed for Phase 2 was skipped per
  the assignment's own conditional.

## Gates (this tree)

| Gate | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS (incl. 5 new native stack-safety cases) |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force` | PASS (incl. 5 new jsoo stack-safety cases) |

## Prediction scoring (sealed set in `journal.md`, scored against measurement)

| Prediction (sealed) | Measured | Score |
| --- | --- | --- |
| dynamic bind >1M on both substrates | PASS at 10M on both | correct |
| static map: native FAIL ~262k, jsoo FAIL ~6k | PASS at 3M on both | wrong on both |
| concat: native FAIL ~225k, jsoo FAIL ~5k | PASS at 1M+ on both | wrong on both |
| bind_error: native FAIL ~65k, jsoo FAIL ~3k | PASS at 3M on both | wrong on both |
| cause trees: native FAIL ~65k, jsoo FAIL ~4k | PASS at 3M on both | wrong on both |
| verdict: Phase 2 triggered (high confidence) | Phase 2 not triggered | wrong |
| Phase 2 perf deltas | no Phase 2 | vacuous |

2 of 12 case/substrate predictions correct; the headline verdict prediction
was wrong. The flawed mental model: "non-tail recursion dies at fixed-stack
limits (8 MiB native C stack, ~1 MiB V8 stack)". Both substrates defeat it —
OCaml 5 moved OCaml evaluation off the C stack entirely, and jsoo's
`--effects=cps` trampolines exactly the code paths (effect-reaching) that an
effect interpreter exercises. The experiment's value is precisely here: the
audit claim was plausible from code reading and is empirically false on the
shipped substrates, and now the guarantee is pinned by regression tests
rather than by argument.

## Recommendation

1. Accept the verdict: no trampoline rewrite. A rewrite now would add
   interpreter risk and hot-path cost to fix a failure that does not exist
   on either shipped substrate.
2. Keep the promoted regression corpus in the standard gates (done in this
   branch): it converts the audit's "unestablished" into a continuously
   checked guarantee on both substrates.
3. Reopen only if a new substrate appears (bytecode, non-CPS jsoo, or a
   bounded-stack runtime) or if a future interpreter change removes the
   properties the substrate mechanisms rely on — the regression tests are
   the tripwire for the latter.

`E35 READY FOR REVIEW`
