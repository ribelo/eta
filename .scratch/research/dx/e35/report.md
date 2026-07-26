# DX-E35 report — stack-safety probe of the Eta interpreter

Date: 2026-07-26 (follow-up 1 corrections applied same day).
Branch: `research/dx-e35-stack-safety`.
Experiment record: `journal.md` (sealed predictions + dated follow-up note),
`probe/` (boundary corpus + raw evidence), this file (verdict and scoring).

## Question

Audit claim under test (`.scratch/research/eop-audit-2026-07-26.md` §4.1):
the interpreter descends recursively through `Map`/`Bind` with no trampoline
and no explicit continuation stack, and `concat` builds statically nested
binds via `List.fold_left` — therefore stack safety is unestablished.

## Verdict (accepted with conditions, follow-up 1 applied)

**The interpreter is stack-safe at 1M under documented default
configurations on shipped substrates — 1 GiB default OCaml `stack_limit`
native/bytecode, CPS js_of_ocaml — and the guarantee is
configuration-dependent, not intrinsic.** No Phase 2; the interpreter is
untouched. Precisely:

- **Pinned contract:** every corpus composition (dynamic bind chain, static
  deep `map` nesting, `concat` of prebuilt effects, deep `bind_error`
  recovery, left-deep `Cause.Sequential`/`Concurrent` construction plus
  `Cause.failures` traversal) completes at depth **1,000,000** on native
  OCaml 5.4.1, bytecode OCaml 5.4.1, native OxCaml 5.2.0+ox, bytecode
  OxCaml 5.2.0+ox, and js_of_ocaml `--effects=cps`/Node 24, with full
  semantic verification per run.
- **Native/bytecode boundary mechanism:** OCaml 5 evaluates on
  heap-allocated, growable fiber stacks bounded by `Gc.stack_limit`,
  measured default **134,217,728 words = 1 GiB** on 64-bit (both
  compilers). The 8 MiB `ulimit -s` C stack is not the bounding resource.
- **Reopeners:** a user-selected `OCAMLRUNPARAM=l=<words>` lowers the
  native/bytecode bound (demonstrated: `static_map` fails with a caught
  `Stack_overflow` at 1M under `l=1000000`, and at 100k under `l=100000` —
  `probe/STACKLIMIT.raw.txt`). Non-CPS js_of_ocaml is excluded by
  `lib/jsoo/eta_jsoo.mli`'s own `--effects=cps` requirement. A future
  bounded-stack substrate reopens the question.

Nothing in this experiment claims "arbitrarily deep" or intrinsic stack
safety; the regression tests pin exactly the 1M-under-defaults contract.

## Probe numbers

Corpus: `probe/` (standalone dune project, six cases, fresh process per
run, 300 s timeout). Semantic checks (strengthened under follow-up C2):
exact final value (`dynamic_bind`, `static_map`), exact effect-execution
count (`concat`: counter-incrementing `Effect.sync` leaves must execute
exactly `depth` times — an `Ok ()` result alone cannot reveal skipped
effects), exact recovery-handler count (`bind_error`), and every cause
leaf validated against its index (`cause_*`). Raw logs:
`probe/RESULTS.raw.txt` (mainline), `probe/RESULTS.ox.raw.txt` (OxCaml),
`probe/CALIBRATE.raw.txt`, `probe/BEYOND.raw.txt`,
`probe/STACKLIMIT.raw.txt`, `probe/JS-EVAL-TRAMPOLINE.raw.txt`.

| Case (10k / 100k / 1M) | native 5.4.1 | byte 5.4.1 | jsoo/Node 24 | native ox | byte ox |
| --- | --- | --- | --- | --- | --- |
| dynamic bind | PASS | PASS | PASS | PASS | PASS |
| static map | PASS | PASS | PASS | PASS | PASS |
| concat | PASS | PASS | PASS | PASS | PASS |
| bind_error | PASS | PASS | PASS | PASS | PASS |
| cause sequential | PASS | PASS | PASS | PASS | PASS |
| cause concurrent | PASS | PASS | PASS | PASS | PASS |

54/54 mainline runs, 36/36 OxCaml runs. No failure mode
(stack_overflow, segfault, OOM, hang) was observed at any checkpoint, so
no boundary bisection was applicable. Beyond-matrix observation (not part
of the contract): 10M dynamic binds and 3M static structures pass on
native + jsoo. 1M per-case wall time: native 10–198 ms, bytecode
52–361 ms, jsoo 96 ms–1.5 s — the basis for pinning 1M in the gates.

## Mechanism (T10: one semantics, two substrates)

The audit's code reading is confirmed (`eval` at
`lib/eta/effect_core.ml:174`: non-tail `Map` application, non-tail
descent into `inner` for `Bind`, `concat` left-deep chain). Each
substrate absorbs the recursion differently:

- **Native + bytecode:** OCaml 5 growable fiber stacks, bounded by
  `stack_limit` (default 1 GiB), raising a catchable `Stack_overflow`
  past the limit — Eta surfaces it as an `Exit.Error` defect
  (demonstrated in `STACKLIMIT.raw.txt`).
- **js_of_ocaml:** the **whole `eval` function is CPS-transformed
  because its branches and callbacks are effect-capable** — the `Custom`
  leaf's `eval` field is a callback able to perform OCaml effects, so
  jsoo CPS-transforms the function wholesale, including the pure
  `Map`/`Bind` branches that never dynamically reach a `Custom` node
  (`static_map` and unit `concat` are examples). The compiled body
  (`probe/JS-EVAL-TRAMPOLINE.raw.txt`, excerpted from
  `probe_jsoo.bc.js`) shows the call sites directly: `Map` and `Bind`
  recurse through `caml_exact_trampoline_cps_call(eval$, frame, inner,
  cont)`, `Custom` dispatches through
  `caml_trampoline_cps_call2(eval$0, frame, cont)`, guarded by
  `caml_stack_check_depth` — per-level JS stack use is O(1). Control:
  raw non-effectful OCaml recursion compiled by the same jsoo is
  direct-style and dies at ~10k (plain JS recursion: 12,513 frames), so
  the 1M–3M Eta passes measure real depth.
- **`dynamic_bind` is not evidence of absorbed frames** (C6): in `eval`,
  the `Bind` continuation `eval frame (k value)` is a *tail* call, so a
  dynamic bind chain never accumulates stack frames on either substrate
  regardless of trampolining or growable stacks. Its pass confirms the
  interpreter loops on tail bind continuations; it says nothing about
  non-tail absorption. The absorption evidence comes from the non-tail
  cases (`static_map`, `concat`, `bind_error`, cause trees).

## Phase 2 sections — not applicable

No rewrite happened: no design note, no parity delta, no red-team
surface, no perf-guard run (the assignment's bench gate is conditional on
Phase 2). Parity of the untouched interpreter is established by the full
existing suite plus the promoted corpus.

## Regression coverage (promoted corpus, thresholds pinned to the contract)

Per follow-up C3, all promoted tests run at the full measured 1M — a
regression moving failure to 200k fails the suite:

| Suite | Cases | Gate |
| --- | --- | --- |
| `test/eta/test_eta_effect_core.ml` (Alcotest) | 5 × 1M (dynamic_bind, static_map, concat, bind_error, cause trees) | `dune runtest` (OxCaml, mainline) |
| `test/eta/run_stack_safety_byte.ml` (bytecode executable on the `runtest` alias) | 6 × 1M | `dune runtest` (added under follow-up C4: `eta.cma` is shipped) |
| `test/js_jsoo/test_eta_jsoo.ml` | 5 × 1M | `dune runtest test/js_jsoo` (mainline) |

Law-registry assessment (follow-up protocol note): the executable-law
registry `LAWS.md` indexes claims by exact normative span in census
`.mli` files. This change adds or alters **no** law-bearing prose in any
`.mli` (the scope fence forbids it; the contract is behavioral and
configuration-dependent, documented here), so no census row is
applicable. If the 1M-under-defaults contract is ever stated in
`effect.mli` prose, the same change must add a registry row pointing at
the named tests above.

## Gates (final tree, after follow-up corrections)

| Gate | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS (incl. 5 native 1M cases + bytecode gate) |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force` | PASS (incl. 5 jsoo 1M cases) |
| probe matrix incl. bytecode (mainline 54, OxCaml 36) | PASS |

## Prediction autopsy (sealed set in `journal.md`)

| Prediction (sealed) | Measured | Score |
| --- | --- | --- |
| dynamic bind >1M on both substrates | PASS at 10M on both | correct — but see caveat below |
| static map: native FAIL ~262k, jsoo FAIL ~6k | PASS at 3M on both | wrong on both |
| concat: native FAIL ~225k, jsoo FAIL ~5k | PASS at 1M+ on both | wrong on both |
| bind_error: native FAIL ~65k, jsoo FAIL ~3k | PASS at 3M on both | wrong on both |
| cause trees: native FAIL ~65k, jsoo FAIL ~4k | PASS at 3M on both | wrong on both |
| verdict: Phase 2 triggered (high confidence) | Phase 2 not triggered | wrong |
| sealed premise: the indirect `Custom.eval` recovery cycle would not be CPS-transformed under jsoo | the whole `eval` is CPS-transformed (branches and callbacks are effect-capable), so the cycle is trampolined | wrong |
| Phase 2 perf deltas | no Phase 2 | vacuous |

**The precise mistake** (shared by both predictors): confusing the 8 MiB
OS C stack (`ulimit -s`) with the stack OCaml code actually runs on, and
assuming a fixed limit where there is a configurable one. OCaml 5
evaluates on heap-allocated fiber stacks that grow on demand up to
`Gc.stack_limit` — default 134,217,728 words (1 GiB) on 64-bit, not the
C stack and not a fixed 8 MiB. The model was wrong about **which stack**
and **which limit**. On the jsoo side, the same fixed-stack model missed
that `--effects=cps` trampolines exactly the effect-capable functions an
interpreter is made of. The `dynamic_bind` "correct" row is credited
with the caveat above: its pass demonstrates a tail call, not absorbed
non-tail frames, so it is not evidence for the absorption mechanism the
other predictions were about.

## Recommendation

1. Accept: no trampoline rewrite. The failure it would fix does not
   exist at the pinned contract on any shipped substrate.
2. Keep the promoted 1M regression corpus in the standard gates on all
   three backends (native, bytecode, jsoo) — done in this branch.
3. State the contract precisely wherever it is cited: "1M under default
   runtime configurations; `OCAMLRUNPARAM=l=…` lowers the native bound;
   non-CPS jsoo excluded; bounded-stack substrates reopen".
4. Reopen if a bounded-stack or non-CPS substrate is added, if the
   default `stack_limit` policy changes, or if a future interpreter
   change removes the properties the substrate mechanisms rely on — the
   regression tests are the tripwire for the last two.

`E35 READY FOR REVIEW`
