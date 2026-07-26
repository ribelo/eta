# DX-E35 probe results — stack boundary measurement

Measured 2026-07-26. All artifacts in this directory; raw machine output is in
`RESULTS.raw.txt` (mainline matrix), `RESULTS.ox.raw.txt` (OxCaml native
matrix), `CALIBRATE.raw.txt` (substrate calibration), and `BEYOND.raw.txt`
(beyond-matrix headroom runs).

## Environment

| Item | Value |
| --- | --- |
| Machine | Linux 7.1.3 x86_64, 32 cores, 123 GiB RAM |
| Native compilers | OCaml 5.4.1 (`.#mainline` shell) and OxCaml 5.2.0+ox (default shell) |
| JS substrate | js_of_ocaml `--effects=cps`, Node v24.18.0 (mainline shell) |
| Shell stack limit | `ulimit -s` = 8192 KiB in both shells |
| Probe build | current worktree via `build.sh` (repo `@install` tree on `OCAMLPATH`) |

Each (backend, case, depth) ran in a fresh process with a 300 s timeout
(`run-case.sh`). A PASS requires the case's own semantic check to succeed:
exact final value (`dynamic_bind`, `static_map`), exact recovery-handler count
(`bind_error`), or exact leaf count and left-to-right order (cause trees) —
mere process survival never counts.

## Matrix results (10k / 100k / 1M, both substrates)

All 36 mainline runs (6 cases x 3 depths x 2 backends) PASS. All 18 OxCaml
native runs PASS. No failure point exists to bisect; the boundary-search
protocol (`bisect.sh`) was therefore not applicable.

| Case | Native 5.4.1 | OxCaml native | jsoo/Node |
| --- | --- | --- | --- |
| `dynamic_bind` 10k/100k/1M | PASS all | PASS all | PASS all |
| `static_map` 10k/100k/1M | PASS all | PASS all | PASS all |
| `concat` 10k/100k/1M | PASS all | PASS all | PASS all |
| `bind_error` 10k/100k/1M | PASS all | PASS all | PASS all |
| `cause_sequential` 10k/100k/1M | PASS all | PASS all | PASS all |
| `cause_concurrent` 10k/100k/1M | PASS all | PASS all | PASS all |

No `stack_overflow`, segfault, OOM, or hang was observed in any run. Failure
modes searched for: caught `Stack_overflow` (Eta defect or top-level), signals,
OOM, timeout — none occurred.

## Beyond-matrix headroom (mainline)

| Run | Native 5.4.1 | jsoo/Node |
| --- | --- | --- |
| `dynamic_bind` 10,000,000 | PASS (41 ms) | PASS (0.4 s) |
| `static_map` 3,000,000 | PASS | PASS (1.4 s incl. tree build) |
| `bind_error` 3,000,000 | PASS | PASS |
| `cause_sequential` 3,000,000 | PASS | PASS |

The interpreter does not exhaust the stack at 3x the required depth for
static structures, or 10x for dynamic chains, on either substrate.

## Substrate calibration (why the passes are real, and why they happen)

Raw limits on this machine (`probe_calibrate`, `CALIBRATE.raw.txt`):

- Plain JS recursion in Node: `RangeError` at 12,513 frames.
- Raw non-tail OCaml recursion compiled by js_of_ocaml `--effects=cps`:
  caught as OCaml `Stack_overflow` already at 10,000 (jsoo compiles
  non-effectful recursion to direct-style JS).
- Raw non-tail OCaml recursion on native OCaml 5.4.1: PASS at 1,000,000.
- Raw tail recursion: PASS at 1,000,000 on both substrates.

So the Eta passes are not an artifact of shallow probe construction (every
run re-verified the full semantic result) and they are not a generic
"JS stack is huge" effect — the same compiler dies at 10k on a raw non-tail
function. The two substrates survive for different reasons:

1. **Native (OCaml 5.4.1 and OxCaml 5.2.0+ox):** OCaml 5 evaluates OCaml code
   on heap-allocated, dynamically growable fiber stacks, not the fixed 8 MiB
   C stack. The recursive `eval` (`Map`/`Bind` descent in
   `lib/eta/effect_core.ml:174`) grows the fiber stack into the heap;
   exhaustion becomes a memory question, not a stack-limit question, at these
   depths.
2. **js_of_ocaml/Node:** `--effects=cps` trampolines CPS-transformed calls.
   The generated `probe_jsoo.bc.js` contains `caml_trampoline_cps_call` (x4640),
   `caml_exact_trampoline_cps_call` (x1112), `caml_trampoline_return` (x461),
   and `caml_stack_check_depth` (x461). Eta's `eval` is CPS-transformed
   (it transitively reaches effect-performing `Custom` leaves), so its
   recursion depth is bounded by the trampoline, not the JS call stack.
   Direct-style code (raw non-effectful recursion) is not protected and dies
   at ~10k, confirming the depth reached through Eta is real.

## Interpretation for the audit claim (eop-audit-2026-07-26.md, section 4.1)

The audit's code reading is confirmed: the interpreter descends recursively
through `Map`/`Bind`/`Custom` with no explicit continuation stack, and
`concat` builds a statically nested left-deep bind chain via
`List.fold_left`. The "stack safety unestablished" worry is nonetheless not
realized on either shipped substrate at any tested depth, because both
substrates absorb the recursion (heap-grown fiber stacks natively; the CPS
trampoline under jsoo). The guarantee is substrate-mediated, not intrinsic:
bytecode, a non-CPS jsoo build, or a substrate with bounded fiber stacks
would reopen the question. The promoted regression tests pin the guarantee
on both shipped substrates.

## Pre-registered verdict

**All cases pass at 1M on both substrates.** Per the assignment's
pre-registered outcomes, Phase 2 is **not triggered**: the interpreter stays
untouched, the corpus is promoted to bounded regression tests, and the
experiment ends with the report. No interpreter files were modified (verified
by `git status` scoping throughout; every commit under `lib/` is absent).

## Reproduction

```sh
nix develop .#mainline -c bash .scratch/research/dx/e35/probe/build.sh
nix develop .#mainline -c bash .scratch/research/dx/e35/probe/run-matrix.sh \
  .scratch/research/dx/e35/probe/RESULTS.raw.txt
nix develop -c bash .scratch/research/dx/e35/probe/build.sh
nix develop -c bash -c \
  'E35_PROBE_BUILD_DIR=$PWD/.scratch/research/dx/e35/probe/_build-ox \
   E35_BACKENDS=native \
   bash .scratch/research/dx/e35/probe/run-matrix.sh \
   .scratch/research/dx/e35/probe/RESULTS.ox.raw.txt'
```
