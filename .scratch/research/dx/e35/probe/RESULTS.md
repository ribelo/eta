# DX-E35 probe results — stack boundary measurement

Measured 2026-07-26; matrix extended and checks strengthened under
follow-up 1 (accept-with-conditions). Raw machine output:
`RESULTS.raw.txt` (mainline matrix: native + bytecode + jsoo),
`RESULTS.ox.raw.txt` (OxCaml matrix: native + bytecode),
`CALIBRATE.raw.txt` (substrate calibration), `BEYOND.raw.txt` (headroom),
`STACKLIMIT.raw.txt` (default limit + reopening evidence),
`JS-EVAL-TRAMPOLINE.raw.txt` (compiled `eval$` call sites).

## The pinned contract

Stack-safe at **1M steps under documented default runtime configurations**
on the shipped substrates: native and bytecode OCaml with the default
`stack_limit` (134,217,728 words = 1 GiB on 64-bit, measured on 5.4.1 and
5.2.0+ox), and js_of_ocaml `--effects=cps` under Node. The guarantee is
**configuration-dependent, not intrinsic**:

- A user-selected `OCAMLRUNPARAM=l=<words>` lowers the native/bytecode
  bound and reopens exhaustion (demonstrated below).
- Non-CPS js_of_ocaml is excluded — `lib/jsoo/eta_jsoo.mli` itself
  requires `--effects=cps`; without it, raw recursion dies at ~10k.
- A future bounded-stack substrate reopens the question.

## Environment

| Item | Value |
| --- | --- |
| Machine | Linux 7.1.3 x86_64, 32 cores, 123 GiB RAM |
| Compilers | OCaml 5.4.1 (`.#mainline`), OxCaml 5.2.0+ox (default shell) |
| Bytecode | `probe_native.bc` on the same two compilers (`eta.cma` is shipped) |
| JS substrate | js_of_ocaml `--effects=cps`, Node v24.18.0 (mainline shell) |
| Default stack_limit | 134,217,728 words (1 GiB) on both compilers (measured) |
| Shell C-stack limit | `ulimit -s` = 8192 KiB — bounds the runtime's C stack only |
| Probe build | current worktree via `build.sh` (repo `@install` tree on `OCAMLPATH`) |

Each (backend, case, depth) ran in a fresh process with a 300 s timeout
(`run-case.sh`). A PASS requires the case's full semantic check: exact
final value (`dynamic_bind`, `static_map`), exact effect-execution count
(`concat`, via counter-incrementing `Effect.sync` leaves), exact
recovery-handler count (`bind_error`), or every cause leaf validated
against its index (`cause_*`). Skipped, duplicated, or reordered work
fails as surely as a stack overflow.

## Matrix results (10k / 100k / 1M per case)

Mainline: 54/54 PASS (6 cases x 3 depths x 3 backends). OxCaml: 36/36
PASS (6 cases x 3 depths x 2 backends). No failure point exists to
bisect; the boundary-search protocol (`bisect.sh`) was not applicable.

| Case | native 5.4.1 | byte 5.4.1 | jsoo/Node | native ox | byte ox |
| --- | --- | --- | --- | --- | --- |
| `dynamic_bind` 10k/100k/1M | PASS | PASS | PASS | PASS | PASS |
| `static_map` 10k/100k/1M | PASS | PASS | PASS | PASS | PASS |
| `concat` 10k/100k/1M | PASS | PASS | PASS | PASS | PASS |
| `bind_error` 10k/100k/1M | PASS | PASS | PASS | PASS | PASS |
| `cause_sequential` 10k/100k/1M | PASS | PASS | PASS | PASS | PASS |
| `cause_concurrent` 10k/100k/1M | PASS | PASS | PASS | PASS | PASS |

No `stack_overflow`, segfault, OOM, or hang was observed in any run.

1M per-case wall times on this machine (includes process startup): native
10–198 ms; bytecode 52–361 ms; jsoo 96 ms–1.5 s. These measurements are
why the promoted regression tests pin the full 1M contract in gate time.

## Beyond-matrix headroom (mainline, observation only — not the contract)

`dynamic_bind` 10,000,000 PASS native + jsoo; `static_map`, `bind_error`,
`cause_sequential` 3,000,000 PASS native + jsoo. Recorded as evidence of
margin above the pinned 1M, not as a widened guarantee.

## Reopening demonstrated: `OCAMLRUNPARAM=l=<words>` (`STACKLIMIT.raw.txt`)

`static_map` on mainline native with reduced stack limits:

| Limit (words) | 10k | 100k | 1M |
| --- | --- | --- | --- |
| 1,000,000 | PASS | PASS | FAIL stack_overflow (Eta defect) |
| 500,000 | PASS | PASS | FAIL stack_overflow (Eta defect) |
| 100,000 | PASS | FAIL stack_overflow | FAIL stack_overflow |

The default-configuration guarantee coexists with a reachable,
user-selectable exhaustion boundary — which is why the contract is stated
at 1M under defaults, not "arbitrarily deep". This also demonstrates the
probe's failure detection end-to-end: the failure mode is a caught
`Stack_overflow`, surfaced by Eta as an `Exit.Error` defect.

## Substrate calibration (why the passes are real, and why they happen)

Raw limits on this machine (`probe_calibrate`, `CALIBRATE.raw.txt`):

- Plain JS recursion in Node: `RangeError` at 12,513 frames.
- Raw non-tail OCaml recursion compiled by js_of_ocaml `--effects=cps`:
  caught as OCaml `Stack_overflow` already at 10,000 (jsoo compiles
  non-effectful recursion to direct-style JS).
- Raw non-tail OCaml recursion on native OCaml 5.4.1: PASS at 1,000,000.
- Raw tail recursion: PASS at 1,000,000 on both substrates.

The three substrates survive Eta's recursion for different reasons:

1. **Native and bytecode (OCaml 5.4.1, OxCaml 5.2.0+ox):** OCaml 5
   evaluates OCaml code on heap-allocated, dynamically growable fiber
   stacks. The 8 MiB `ulimit -s` C stack is not the bounding resource.
   Growth is bounded by `Gc.stack_limit` (default 134,217,728 words =
   1 GiB on 64-bit); exhaustion past the limit raises `Stack_overflow`,
   which Eta captures as a defect — demonstrated above.
2. **js_of_ocaml/Node:** the whole interpreter `eval` is CPS-transformed
   because its branches and callbacks are effect-capable (the `Custom`
   leaf's `eval` field is a callback that can perform OCaml effects, so
   jsoo CPS-transforms the function wholesale — including the pure
   `Map`/`Bind` branches that never dynamically reach a `Custom` node).
   The compiled body (`JS-EVAL-TRAMPOLINE.raw.txt`) shows every branch
   calling through the trampoline: `Map` and `Bind` recurse via
   `caml_exact_trampoline_cps_call(eval$, frame, inner, cont)`, `Custom`
   dispatches via `caml_trampoline_cps_call2(eval$0, frame, cont)`, with
   `caml_stack_check_depth` guarding depth. JS stack usage per evaluated
   level is O(1). Direct-style code (raw non-effectful recursion) is not
   protected and dies at ~10k, confirming the depth reached through Eta
   is real.

## Interpretation for the audit claim (eop-audit-2026-07-26.md, section 4.1)

The audit's code reading is confirmed: the interpreter descends
recursively through `Map`/`Bind`/`Custom` with no explicit continuation
stack, and `concat` builds a statically nested left-deep bind chain via
`List.fold_left`. The "stack safety unestablished" worry is not realized
on any shipped substrate at the pinned 1M contract — for
substrate-specific, configuration-dependent reasons documented above.
The promoted regression tests pin the contract continuously: native
(`test/eta/test_eta_effect_core.ml`, five cases at 1M), bytecode
(`test/eta/run_stack_safety_byte.ml`, six cases at 1M, attached to
`runtest`), and jsoo (`test/js_jsoo/test_eta_jsoo.ml`, five cases at 1M).

## Pre-registered verdict

**All cases pass at 1M on all shipped substrates under default
configurations.** Per the assignment's pre-registered outcomes, Phase 2
is **not triggered**: the interpreter stays untouched, the corpus is
promoted to bounded regression tests pinning the 1M contract, and the
experiment ends with the report. No interpreter files were modified.

## Reproduction

```sh
# mainline matrix (native + bytecode + jsoo)
nix develop .#mainline -c bash .scratch/research/dx/e35/probe/build.sh
nix develop .#mainline -c bash .scratch/research/dx/e35/probe/run-matrix.sh \
  .scratch/research/dx/e35/probe/RESULTS.raw.txt
# OxCaml matrix (native + bytecode)
nix develop -c bash .scratch/research/dx/e35/probe/build.sh
nix develop -c bash -c \
  'E35_PROBE_BUILD_DIR=$PWD/.scratch/research/dx/e35/probe/_build-ox \
   E35_BACKENDS="native byte" \
   bash .scratch/research/dx/e35/probe/run-matrix.sh \
   .scratch/research/dx/e35/probe/RESULTS.ox.raw.txt'
```
