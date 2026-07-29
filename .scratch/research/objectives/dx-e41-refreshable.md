# Objective: DX-E41 — `Resource` → `Refreshable` in `eta_cache` + lexical-first `with_auto`

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e41`
- Branch: `research/dx-e41-refreshable` (already checked out here; do not create others)
- Wave: EOP hardening, item 9/14 · Risk low–med (package move + ownership re-shaping)
- Evidence IDs: `V-DX-E41-*` (orchestrator log); your journal is the branch record

## Executor profile

Package-boundary surgery plus an ownership re-shaping: move a public module
from the root package to `eta_cache`, rename it, and rebuild its
daemon-backed constructor as a scope-owned combinator on public machinery.
The rename/move is the easy 30%. The difficulty is cancellation/scope
correctness on every exit kind, and writing a new public `.mli` contract
that keeps every behavioral claim the old one made. Do not invent scope —
the contract below is fixed.

## Mission and the audit's claim (adjudicated, adopted)

In an effect library, `Resource` reads as acquire/release/scope/ownership —
while the real resource model lives in `Effect.with_resource` /
`acquire_release`. What `Eta.Resource` actually is: a **refreshable cache /
reloadable value / stale-while-refresh holder**. The name steals the wrong
mental model. `eta_cache` is the natural home. And `auto`'s runtime-owned
daemon was the last public consumer of the runtime-owned-background pattern
— the lexical form should be the way.

Consumption model (V-DX-PRINC-1): `Eta.Resource` is public API consumed
externally; in-repo call-site counts bound the repo's migration, NOT the
API's value. The rename is justified by the mental-model fix, not by usage
frequency.

## Read first (in order)

1. `AGENTS.md` — Nix-only gates, no shims, delete old paths, break loudly,
   conventional commits, package-boundary policy (`eta_cache` carries its
   own feature; root `eta` must not depend on it — the reverse direction
   only).
2. `lib/eta/resource.mli` + `resource.ml` — the module being moved. Note
   every behavioral claim in the docs: stale-while-refresh, `failures`
   `Fail`/`Die` classification, `on_error` defect recording, schedule
   exhaustion behavior.
3. `lib/eta/effect.mli` — `with_supervised_background` (your ownership
   model), `with_scope`, `acquire_release`.
4. `lib/cache/` (dune, `eta_cache.mli`) — the destination package.
5. `.scratch/research/dx/e42a/report.md` — what E42a did to `daemon`
   (now SPI) and why `with_auto` must not touch SPI.
6. `docs/research/dx-ledger.md` E41 entry for the wave context.

## The experiment (the contract)

**Rename + move.** `Eta.Resource` → `Eta_cache.Refreshable`
(`lib/eta/resource.ml{i}` moves to `lib/cache/`, renamed). Root `eta` loses
the module entirely — no re-export, no alias, no shim (AGENTS.md: delete
old paths). `Eta_js.Resource` becomes `module Refreshable =
Eta_cache.Refreshable` (eta_cache builds under jsoo; `test/cache_jsoo`
exists — verify).

**`auto` is deleted. `with_auto` is the only background-refresh form:**

```ocaml
val manual : ('a, 'err) Effect.t -> (('a, 'err) t, 'err) Effect.t

val with_auto :
  ?on_error:('err -> unit) ->
  load:('a, 'err) Effect.t ->
  ?random:Capabilities.random ->
  schedule:(unit, 'schedule_out) Schedule.t ->
  (('a, 'err) t -> ('b, 'err) Effect.t) ->
  ('b, 'err) Effect.t
```

(Error-row: single `'err` throughout, unless `with_resource`'s discipline
shows a concrete reason to differ — if you diverge, the journal must say
why in one paragraph.)

**Semantics (preserved from `auto`, re-owned):**
- Seed once before the body runs; seed failure fails the acquisition, body
  never runs.
- The refresh loop is **scope-owned**: body exit of ANY kind (success,
  typed failure, defect, cancellation) stops the loop; in-flight refresh
  cancelled at a checkpoint, finalizers run.
- Schedule exhaustion ends the loop; the body continues with the
  last-loaded value (handle stays usable).
- Stale-while-refresh verbatim: refresh failures keep last good value;
  `failures` records `Cause.Fail`/`Cause.Die` classification; `on_error`
  defect → additional recorded `Die`, loop continues.
- Built on **public machinery only** (`with_supervised_background` or
  `with_scope` + scope primitives). No SPI, no daemon. If no public
  construction satisfies the semantics, that is `E41 BLOCKED: missing core
  primitive <name>` — raw evidence for E43, not something to work around.

**Hold trigger (pre-registered):** a current `auto` call site that
genuinely needs runtime-owned lifetime with no enclosing lexical scope.
Record it verbatim in your journal; do NOT keep `auto` for it, do NOT work
around it. The orchestrator decides what that evidence means.

## Protocol (predictions commit FIRST; then docs-first; then implementation)

1. **Seal your predictions** in `.scratch/research/dx/e41/journal.md`:
   expected census deltas, expected migration size, your read of the
   scope-exit semantics tests you'll write, two likeliest review
   reservations. Commit before any code change
   (`docs(dx-e41): seal predictions`). Never edit afterward. (The
   orchestrator's set is already sealed on master — do not read
   `.scratch/research/dx-journal.md`; the scope fence below applies.)
2. **Docs-first.** Write `lib/cache/refreshable.mli` (or the renamed
   equivalent) before the `.ml`: every behavioral claim from the old
   module preserved or explicitly amended, the `with_auto` contract within
   the doc budget, and the stale-while-refresh section verbatim-in-spirit.
   Check the law registry (`.scratch/research/dx/e22/review/LAWS.md`) for
   rows covering `resource.mli` claims — they must keep coverage pointing
   at the new module; update rows in the same change (AGENTS.md law policy).
3. **Implement.** Move, rename, rebuild the constructor on public
   machinery, migrate every call site (2 examples, 2 test files,
   `eta_js`), rewire dune deps, update the 4 docs files. Follow the
   CHANGELOG pattern of the recent EOP-wave merges (look at how E39/E40/
   E42a extended it).
4. **Gates** (exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo
   ```
   Fix-forward up to three attempts per failure class, then BLOCKED.
5. **Mechanical extras.**
   - **Scope-exit suite**: refresh loop stops on body success, typed
     failure, defect, and cancellation (4 tests); in-flight refresh
     cancellation; no fiber leak after scope exit (use the runtime's fiber
     accounting if public — check `Eta_test` — otherwise a documented
     probe).
   - **Semantics preservation**: stale-while-refresh after failed refresh;
     `failures` ordering and `Fail`/`Die` classification; `on_error`
     defect recorded; schedule exhaustion → loop ends, handle stays
     usable; seed failure → body never runs.
   - **Census table**: root eta / eta_cache modules and vals before/after
     (orchestrator pre-counts in the sealed predictions — verify
     independently, do not read them first: count BEFORE checking your
     answer).
   - **Footgun delta**: expect −1 (the name collision).
6. **Red-team pass.** Write the bug the OLD name invited: a user reading
   `Resource.auto` as acquire/scope ownership (expecting the handle to be
   release-fenced) — show what the new name/shape does to that misreading,
   and try to leak the refresh loop past its scope (must be impossible
   without SPI). Commit under `.scratch/research/dx/e41/redteam/` with
   verdicts.
7. **Report** in `.scratch/research/dx/e41/report.md`: gates summary,
   scope-exit and preservation evidence, census/footgun actuals vs your
   sealed predictions (scored explicitly), hold-trigger audit (any
   runtime-owned-lifetime need found? raw quotes), red-team outcome,
   deviations, and your promote/hold/kill recommendation.

## Done means

Your final message ends with exactly one of:

- `E41 READY FOR REVIEW`
- `E41 BLOCKED: <reason>`
- `E41 STOP: <stop condition>`

The orchestrator verifies (diff, focused tests, evidence audit), runs the
independent PR-style review, and decides. Rework via follow-up messages.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md` (orchestrator's
  sealed predictions), `docs/research/dx.md`, `docs/research/dx-ledger.md`
  beyond the E41 entry, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E41's surface. Adjacent footguns → journal follow-ups, not this
  diff.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e41/` must be committed.
