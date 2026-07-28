# Objective: DX-E40 — `all` admission split

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e40`
- Branch: `research/dx-e40-all-admission-split` (already checked out here; do not create others)
- Wave: EOP-audit hardening · Effort S–M · Risk med (concurrency semantics change)
- Evidence IDs: `V-DX-E40-*` (orchestrator log); your journal is the branch record

## Executor profile

A concurrency-semantics change with a small migration surface. `all`
stops hiding a magic number: it becomes unbounded (deadlock-immune), the
bound becomes an explicitly-named sibling operation, and deadlock
semantics get pinned by discriminating tests in BOTH directions. The
difficulty is not the code volume — it is the concurrency engine care
(fork-all vs. worker-pool) and the test design: a deadlock guarantee and
a deadlock *possibility* must each be proven, not asserted.

## Mission

Eta may be complicated inside; using Eta must feel beautiful — and a
hidden number that can silently stall a coordinator is not beautiful.
Neither ZIO nor Effect-TS ships a magic-number bounded default (Finder
evidence, audit grill). The EOP audit's sentence stands: the hidden 8 is
ergonomic but semantically too costly. `map_par`'s documented default-8
is a different case — measured, documented, and out of scope.

## Consumption model (V-DX-PRINC-1)

Eta is consumed primarily by EXTERNAL consumers. In-repo unusedness is
not evidence of unnecessity; frequency gates apply only absent a
structural need.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file. Law policy:
   `effect.mli` is census-complete; `all`'s admission/deadlock law rows
   change meaning and MUST be updated in the same change.
2. `.scratch/research/eop-audit-2026-07-26.md` §4.7 — the admission claim.
3. `lib/eta/effect.mli` — `all`, `all_settled`, `map_par` contracts
   (note the current deadlock warning on `all`).
4. `lib/eta/effect_concurrent.ml` — `all` (worker pool, default 8),
   `all_settled` (fork-all). Two admission engines, side by side today.
5. The deadlock tests in `test/core_common/effect_common_suites.ml`
   (E28's discriminating tests) — you will adapt them.
6. `.scratch/research/dx/e28/report.md` — the decision this experiment
   amends (E28 unified admission under a hidden default; the audit grill
   flipped it).

## The change (registered split)

```ocaml
val all : ('a, 'err) t list -> ('a list, 'err) t
  (* unbounded: every child admitted immediately — deadlock-immune *)

val all_bounded :
  max_concurrent:int -> ('a, 'err) t list -> ('a list, 'err) t
  (* REQUIRED bound; Invalid_argument if <= 0; coordination caveat
     documented — a bound smaller than a coordination group can stall *)

val all_settled : (* unchanged signature; docs aligned to the shared
                     admission model — it already forks every child *)
```

`map_par`: untouched. `all_settled_bounded`: do NOT add — if the question
surfaces, record it as a deferred note in your journal (YAGNI until a
structural need is named).

**Semantics (unchanged unless stated):** fail-fast, input-order results,
first-failure cause propagation, cancellation/finalizer behavior — all
preserved from E28 and pinned by the existing suite. The only semantic
delta is admission: omission no longer means 8, it means every child.

## Protocol

1. **Seal YOUR predictions** in `.scratch/research/dx/e40/journal.md`
   BEFORE any code change: predicted omission-site classifications
   (safe-to-widen vs. load-bearing), predicted deadlock-test outcomes,
   predicted census/footgun deltas. Commit first. Never edit. (The
   orchestrator's set is sealed on master, V-DX-E40-001 — do not read
   `.scratch/research/dx-journal.md`.)
2. **Docs-first.** The new `all`/`all_bounded` mli contracts before the
   engine change. The `all_bounded` doc must carry the coordination
   caveat in one sentence (the E28 warning, sharpened to the named
   operation). The `all` doc must state deadlock-immunity as a contract,
   not a hope. `docs/api-dx.md` concurrency guidance updated: when to
   reach for `all_bounded` — answer that question in the docs, the
   review will check.
3. **Implement.** `all` becomes fork-all (share machinery with
   `all_settled` where honest — do not contort); `all_bounded` keeps the
   E28 worker pool, required label, `Invalid_argument` on ≤ 0 at
   construction.
4. **Migrate.** 7 `~max_concurrent` sites → `all_bounded`. Census every
   `Effect.all` omission site (~9 + bench fixtures): classify
   safe-to-widen vs. load-bearing, one line each in your journal. A
   load-bearing bound migrates to `all_bounded`; none may be silently
   re-bounded.
5. **Gates:**
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo test/signal_jsoo test/http_js
   ```
6. **Mechanical extras.**
   - **Deadlock pinned both ways** (discriminating tests): (a) a barrier
     shape (N children, each waits for all siblings' signals) with
     `all_bounded ~max_concurrent:(N-1)` stalls — proven via timeout and
     documented as the named caveat; (b) the SAME shape under `all`
     completes — the new immunity guarantee. E28's tests adapted.
   - **Parity:** fail-fast, input order, cancellation, finalizer
     behavior on the new `all` (existing suite must cover; add what's
     missing).
   - **Construction-time rejection:** `all_bounded ~max_concurrent:0`
     and negative fail loudly at construction (parity with `map_par`).
   - **Census:** concurrency cluster delta (+1 val, `all` loses its
     optional); footgun delta (expect −1/+0).
   - **Law registry:** every `all` admission/deadlock row updated to the
     new semantics; no orphans, no stale claims.
7. **Review packet** — NOT snippet theater (retired). Assemble
   `.scratch/research/dx/e40/dossier/`: the new mli contracts, the
   docs answer to "when `all_bounded`", the deadlock test pair with
   outputs, the omission-site census, the law diffs. The orchestrator's
   review reads the change PR-style.
8. **Report** per the usual shape: gates, evidence vs. your sealed
   predictions (scored), deviations, recommendation.

## Done means

Final message ends with exactly one of:

- `E40 READY FOR REVIEW`
- `E40 BLOCKED: <reason>`
- `E40 STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`,
  `docs/research/`, `.scratch/research/dx-prd-0001.md`,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E40's surface: `all`, `all_bounded`, `all_settled` docs, their
  engines, call sites, tests, and law rows. `map_par` is OUT of scope
  except docs disambiguation. If you find a semantic tangle (e.g.
  `all_settled` secretly sharing the worker pool), STOP and report.
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e40/` must be committed.
