# Objective: DX-E26 — `Effect.fresh` (Phase D warm-up)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e26`
- Branch: `research/dx-e26-effect-fresh` (already checked out here; do not create others)
- Phase: D (runtime & model) · Effort S · Risk low
- Evidence IDs: `V-DX-E26-*` (orchestrator log); your journal is the branch record

## Executor profile

A small but cross-cutting runtime addition: one capability (a per-runtime
monotonic counter) threaded through the core signature, the native backend,
the jsoo backend, and the test runtime — plus docs and tests. The
difficulty is finding the right seams in the runtime (capabilities,
runtime contract, test-runtime reset), not volume. Docs-first; no design
invention beyond the contract below.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Fiber names,
span-correlation ids, and test fixtures need unique tokens; today each
module rolls its own counter or abuses `Random`. One honest leaf fixes
that. (Imported from fused-effects `Fresh`; cite `Control.Effect.Fresh`
in the journal's provenance note.)

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/eta/capabilities.mli` — how `random` is shaped (`random_of_seed`);
   your capability follows the same discipline.
3. `lib/eta/runtime_core.ml` and `runtime_contract.ml` — note the EXISTING
   ad-hoc counters (`fresh_context_id` in `tracer.ml`,
   `fresh_interrupt_id` in `cause.ml`, service-key `fresh`,
   `fresh_runtime_id`). These are process-global Atomics with cross-runtime
   jobs — **do not unify them with this experiment's per-runtime counter**;
   the distinction is the one real design point and your mli must teach it.
4. The `Eta_test` runtime — where deterministic reset happens.
5. The jsoo runtime (`lib/jsoo/`) — the plain-mutable-cell home (T10).

## The experiment (one-pager, from DX-PRD-0001 §E26)

```ocaml
val fresh : unit -> (int, 'err) t
val fresh_named : string -> (string, 'err) t  (* "worker-7" from prefix *)
```

Runtime-owned monotonic counter capability; per-runtime uniqueness, no
cross-domain guarantees beyond that (documented). Deterministic under
`Eta_test` (counter resets with the test runtime). Zero allocation beyond
the counter; thread-safe on the runtime substrate. jsoo: plain mutable
cell per runtime — portable (T10).

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Proof obligations: monotonicity, uniqueness under concurrency, test
determinism, both backends compiling and behaving. Small surface — keep
the evidence small and exact.

Working artifacts in `.scratch/research/dx/e26/` **on this branch**
(commit them): `journal.md`, `report.md`, `redteam/`, `review/`.

## Protocol

1. **Seal your predictions** in `.scratch/research/dx/e26/journal.md`
   before any code change (`docs(dx-e26): seal predictions`).
2. **Docs-first.** Write the `.mli` contracts for `fresh`/`fresh_named`
   before implementing. Must state, within budget: per-runtime monotonic;
   NOT globally unique (distinct runtimes and domains may repeat values —
   correlate across runtimes needs your own namespacing); `Eta_test`
   resets the counter (determinism contract); `fresh_named` is
   convenience formatting over `fresh`, not a second counter.
3. **Implement** the capability + both backends + test-runtime reset.
4. **Gates** (from the worktree, exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo
   ```
   (`signal_jsoo` is expected-fail on master — do not touch it.)
5. **Mechanical extras.**
   - Tests: strictly-increasing sequence; uniqueness under `par` (N
     concurrent pulls, all distinct); test-runtime determinism (same
     program against two fresh test runtimes → same sequence);
     `fresh_named "worker"` shape (`"worker-7"`).
   - Census: construct cluster +2 vals / +1 concept; footguns +0 (record
     the per-runtime trap candidate and how the mli disarms it).
   - `docs/api-dx.md`: add `fresh`/`fresh_named` to the construct
     guidance if it fits the page's voice.
6. **Red-team pass** in `.scratch/research/dx/e26/redteam/`: (a) use
   `fresh` where a global id was needed (two runtimes) — show the
   collision and record whether the mli warned about it; (b) `fresh`
   inside a tight `map_par` loop — uniqueness under contention, measured.
7. **Review packet** in `.scratch/research/dx/e26/review/`: one realistic
   call-site pair — a worker-spawning snippet hand-rolling a counter
   (`*-old.ml`) vs using `fresh_named` (`*-new.ml`); `MANIFEST.md`;
   `QUESTIONS.md` ("are these ids unique everywhere?" / "what happens on
   a second run of the same test?").
8. **Report** in `.scratch/research/dx/e26/report.md`: gates, tests,
   census/footguns vs. predictions (scored), red-team outcome, your
   promote/kill recommendation against the one-pager's gate (promote
   unless `Random`-based DIY is found adequate — say why it isn't, or
   kill honestly if it is).

## Done means

Your final message ends with exactly one of:

- `E26 READY FOR REVIEW`
- `E26 BLOCKED: <reason>`
- `E26 STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E26 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E26's surface: capabilities/runtime contract, both backends,
  `Eta_test`, tests, docs. Do NOT migrate the four existing global
  counters or any example code — journal notes only.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e26/` must be committed.
