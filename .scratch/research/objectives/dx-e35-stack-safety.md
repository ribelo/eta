# Objective: DX-E35 — Stack-safety probe (and, on measured failure, trampolined interpreter)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e35`
- Branch: `research/dx-e35-stack-safety` (already checked out here; do not create others)
- Phase: hardening wave (EOP audit) · Effort M (probe) → L (if trampoline) · Risk med–high (interpreter surgery if reached) · **P0 — a core-guarantee question**
- Evidence IDs: `V-DX-E35-*` (orchestrator log); your journal is the branch record

## Executor profile

Two-phase experiment. Phase one is honest measurement: build a boundary
corpus that establishes exactly where (and whether) the interpreter
exhausts the stack, on BOTH substrates. Phase two — only if the
measurement demands it — is interpreter surgery: an explicit
continuation stack / trampoline, with identical semantics and a perf
guard. The failure mode to avoid: reaching for the rewrite before the
numbers say so, or reporting "seems fine" without numbers.

## Mission

An effect library's stack safety is a core guarantee, not a feature. The
audit (§4.1) verified: the interpreter descends recursively through
`Map`/`Bind`, no trampoline, no explicit continuation stack; `concat`
builds statically nested binds via `List.fold_left`. This experiment
establishes the truth and, if needed, fixes it.

## Read first (in order)

1. `AGENTS.md`.
2. `lib/eta/effect_core.ml` — the `eval` recursion shape (Map/Bind/
   Custom), `concat`, `run_child`, frame handling.
3. `lib/jsoo/eta_jsoo.ml` — the CPS interpreter on the JS backend (the
   recursion shape there is the T10 question).
4. `bench/runtime_watchlist/` — the perf guard harness you will use if
   the rewrite happens.
5. `.scratch/research/eop-audit-2026-07-26.md` §4.1 (the claim you're
   testing).

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Artifacts in `.scratch/research/dx/e35/` **on this branch** (commit
them): `journal.md`, `probe/` (the boundary corpus), `report.md`.

## Phase 1 — the boundary probe

Build a probe corpus (a small standalone dune project under the
artifact dir, runnable on both backends) measuring at what depth the
current interpreter exhausts the stack:

- sequential `bind` chains: 10k, 100k, 1M steps (dynamic construction);
- static deep `map` nesting: same depths;
- `concat` of 100k–1M effects;
- deep recovery nesting (`bind_error` chains), 10k–100k;
- deep `Cause` trees (Sequential/Concurrent nesting) if reachable via
  public combinators;
- each case on native AND under `js_of_ocaml` (node).

Record exact failure points and failure MODE (stack_overflow exception,
segfault, OOM, hang) per case per substrate in `probe/RESULTS.md`.

**Pre-registered outcomes:**
- **All pass at 1M on both substrates** → verdict documented, corpus
  promoted to regression tests, interpreter untouched, experiment ends
  (report + review + promote the evidence).
- **Any case fails on any substrate** → Phase 2 (below). jsoo failing
  alone is enough to trigger Phase 2 (T10: one semantics, two
  substrates).

## Phase 2 — the trampolined interpreter (only on measured failure)

Replace recursive descent with an explicit continuation stack / loop in
the interpreter, preserving semantics exactly. Constraints:

- **Identical observable semantics**: the full existing test suite is
  the parity oracle — zero behavioral changes accepted (exit values,
  cause trees, cancellation timing, finalizer order, span structure).
- **T10**: both backends implement the same guarantee; if the jsoo
  interpreter's shape differs, its paragraph in the report explains why
  the guarantee still holds.
- **Perf guard**: `bench/runtime_watchlist` on the final tree vs.
  baseline — hot paths within noise (≤ ~5% or individually justified in
  the report). A trampoline that halves the hot path is not acceptable.
- The probe corpus must then pass at 1M on both substrates, and become
  regression tests (bounded runtime — pick the fastest-checking depths
  that still discriminate, e.g. 100k–1M native / 10k+ jsoo).

## Gates

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force
# if Phase 2: also
nix develop -c bash bench/run.sh --quick   # or the runtime_watchlist subset
```

## Protocol

1. **Seal your predictions** in `journal.md` (failure depths per case
   per substrate, verdict, perf delta if Phase 2) — commit before any
   code (`docs(dx-e35): seal predictions`). Never edit after.
   (Dual-sealing: orchestrator's set is inherited on master; do not read
   it — fence below.)
2. **Probe first, verdict second, surgery (if any) third** — each
   committed separately, in that order.
3. Docs-first ONLY if Phase 2 (the interpreter's loop/stack design note
   in the report before implementing).
4. **Gates** as above; fix-forward ≤ 3 attempts per failure class, then
   BLOCKED.
5. **Red-team pass**: after any rewrite, attack the guarantee — deepest
   corpus case + one adversarial case of your own design (e.g.,
   interleaved deep binds with cancellation at depth, deep chains with
   finalizers at every step).
6. **Report**: probe numbers, verdict, design note (if Phase 2), parity
   evidence, perf guard results, prediction scoring, recommendation.

## Done means

- `E35 READY FOR REVIEW`
- `E35 BLOCKED: <reason>`
- `E35 STOP: <§4.6 stop condition>`

Orchestrator verifies and runs the adversarial review. Rework via
follow-ups.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Phase 1 touches nothing outside the probe artifact dir. Phase 2
  touches the interpreter and its tests only — no public API changes,
  no mli changes (the guarantee is behavioral, not a new signature).
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e35/` must be committed.
