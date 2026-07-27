# Objective: DX-E37 — Parallel-acquire ownership: one canonical combinator

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e37`
- Branch: `research/dx-e37-parallel-acquire` (already checked out here; do not create others)
- Phase: hardening wave (EOP audit §4.3) · Effort M · Risk med (scope/cancellation semantics) · **P0**
- Evidence IDs: `V-DX-E37-*` (orchestrator log); your journal is the branch record

## Executor profile

Resource/cancellation semantics specialist. The difficulty is finalizer
ordering under every exit kind, ownership transfer between scopes, and
the partial-acquire race — with deterministic tests for each. The code
volume is small; the correctness bar is E36-tier.

## Mission

Today, acquiring N resources in parallel with correct cleanup has no
first-class API: the documented recipe requires `Effect.Expert` to
re-register releases into the owner scope. A correctness-shaped user
task should not need the runtime extension point. Build the canonical
combinator — ownership semantics, not ergonomics. **Hard constraint from
E6: no arity zoo, no ergonomic relitigation.** E6's killed `with_2`/
`with_3` were CPS ergonomic wrappers; your combinator exists because
ownership transfer is broken without it, not because the ladder is noisy.

## Read first (in order)

1. `AGENTS.md`.
2. `lib/eta/effect.mli` — `acquire_release` (its own doc names the gap:
   children get their own finalizer scope), `with_scope`,
   `with_resource`, `map_par`'s current admission contract.
3. `docs/api-dx.md` ~line 460–520 — the current Expert-bridge recipe you
   are obsoleting.
4. `git show research/dx-e6-scoped-with-2-3:.scratch/research/dx/e6/report.md`
   — why ergonomic helpers died; the constraint you're under.
5. `lib/eta/effect_resource.ml` (or its neighbor) — scope/finalizer
   machinery.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Artifacts in `.scratch/research/dx/e37/` **on this branch** (commit
them): `journal.md`, `report.md`, `redteam/`.

## The experiment

**Shape (decided upstream).**

```ocaml
val acquire_all_par :
  ?max_concurrent:int ->
  acquire:('c -> ('a, 'err) t) ->
  release:('a -> (unit, 'r) t) ->
  'c list -> ('a list, 'err) t
```

Homogeneous (shards, connections, workers — the canonical case, zero
arity problems). Heterogeneous stays with the E6 ladder or the advanced
path; a clean heterogeneous primitive is a *bonus*, not a requirement —
do not grow the surface to chase it.

**Semantics to pin (each needs a named test):**
1. Acquisitions run concurrently; `?max_concurrent` mirrors `map_par`'s
   current admission contract (default and rejection rules).
2. ANY acquire failure → already-acquired released in **reverse
   successful-acquisition order**; the failure propagates.
3. Cancellation mid-acquisition → same reverse-order cleanup; an
   in-flight acquisition that later completes does NOT register a
   release.
4. Success → ownership transferred to the enclosing scope; releases run
   in reverse order at scope exit on success, typed failure, defect,
   and interruption.
5. Release failures → finalizer diagnostics per existing cause
   semantics (never silently dropped).
6. Results in input order.

**Public surface uses NO Expert** — the Expert-bridge pattern becomes
library-internal or is replaced by a cleaner internal path.

**Docs.** `docs/api-dx.md`'s recipe re-points to the combinator; the
Expert-bridge note is demoted to heterogeneous/advanced. mli contract ≤
~10 lines covering 1–6; if it doesn't fit, the shape is wrong — STOP
and report (the kill path).

**Census/footguns.** +1 val; −1 footgun ("parallel acquisition requires
Expert" closed).

## Gates

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force
```

## Protocol

1. **Seal your predictions** in `journal.md` (semantics per edge,
   migration of the docs recipe, census delta, review outcome) — commit
   before code (`docs(dx-e37): seal predictions`). Never edit after.
   (Dual-sealing: orchestrator's set is inherited on master; do not read
   it — fence below.)
2. **Docs-first**: the `.mli` contract before implementation (≤ ~10
   lines; the budget IS the design check).
3. Implement the smallest correct combinator.
4. Gates as above. Fix-forward ≤ 3 attempts per failure class, then
   BLOCKED.
5. **Mechanical extras**: the six pinned tests; law-registry rows for
   new law-bearing claims; census/footgun deltas.
6. **Red-team pass** in `redteam/`: (a) A completes, B fails while C is
   in-flight — assert A released promptly in reverse order, C cancelled
   and never registers; (b) acquire-under-cancellation that completes
   late — assert no release registers and no leak (fiber census);
   (c) a release that itself fails during scope exit — assert finalizer
   diagnostics preserve the primary cause.
7. **Report**: contract, semantics evidence per edge, docs migration,
   census/footgun actuals vs. predictions (scored), red-team outcome,
   recommendation.

## Done means

- `E37 READY FOR REVIEW`
- `E37 BLOCKED: <reason>`
- `E37 STOP: <§4.6 stop condition>`

Orchestrator verifies and runs the adversarial review. Rework via
follow-ups.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E37's surface: the combinator, its tests, its docs, the
  api-dx recipe re-point. No E6 relitigation, no heterogeneous arity
  variants, no Expert-surface changes.
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e37/` must be committed.
