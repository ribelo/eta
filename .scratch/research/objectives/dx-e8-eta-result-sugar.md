# Objective: DX-E8 — `[%eta.result "name" body]` leaf sugar

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e8`
- Branch: `research/dx-e8-eta-result-sugar` (already checked out here; do not create others)
- Phase: C (syntax & PPX) · Effort S · Risk low
- Evidence IDs: `V-DX-E8-*` (orchestrator log); your journal is the branch record

## Executor profile

Small, precise PPX extension on a warm path: `expand_sync_like` already
takes a `~kind`; you add a `"result"` kind, register `[%eta.result]`,
generalize one error message, add snapshot + parity evidence, then convert
example leaves with *stated judgment* (which leaves deserve span names).
The difficulty is AST hygiene, snapshot tooling, and honest per-site
adoption decisions — not design. The expansion contract below is exact.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Sugar exists
only for unambiguous boundaries (T4): the named leaf is the most frequent
mechanical pattern in the library (`Effect.fn __POS__ __FUNCTION__
(Effect.named "x" (Effect.sync_result …))` — four concepts, one intent).
The expansion must be code a reviewer would accept verbatim in a PR.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/ppx/ppx_eta.ml` — especially `expand_sync_like` (line ~21),
   `expand_fn`, and the `Extension.V3.declare` registrations.
3. `test/ppx_expansion/` — the snapshot corpus format and
   `snapshot_expansions.sh`.
4. `test/ppx_common/ppx_common_suites.ml` — the golden in-memory-tracer
   tests (E7's pattern for behavioral parity).
5. `.scratch/research/dx/e7/report.md` — the previous PPX experiment's
   executor record (format to match).
6. `docs/api-dx.md` leaf-boundary guidance — you'll update it.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
The design is decided (expansion contract below is exact); skip
hypothesis-space theatre. Proof obligations: expansion fidelity (snapshots),
behavioral parity with the hand-written form (runtime + tracer), and honest
adoption accounting (which sites converted, which didn't, why).

Working artifacts in `.scratch/research/dx/e8/` **on this branch** (commit
them): `journal.md`, `report.md`, `redteam/`, `review/`.

## The experiment (one-pager, amended by E1's outcome)

**Proposal.**

```ocaml
let user = [%eta.result "db.find" (Db.find db id)]
(* expands to *)
Effect.fn __POS__ __FUNCTION__
  (Effect.named "db.find" (Effect.sync_result (fun () -> Db.find db id)))
```

**Scope amendment (orchestrator, evidence-based):** `[%eta.option]` is OUT
of scope. E1 killed `sync_option` (zero usage evidence, V-DX-E1-002) — the
substrate does not exist. Sugar follows demonstrated frequency (T4), not
symmetry. Do not add it.

**Semantics & edges.** Inherits E1's channel semantics (`Error e` → typed
failure; exception → `Cause.Die`); the PPX adds span naming and location,
nothing else (T9 — no inferred names, no ambient magic).

**Gates from the one-pager.** Promote with E1 (promoted). Kill the day the
expansion needs explaining.

## Protocol (predictions commit FIRST and separately; then step commits)

1. **Seal your predictions** in `.scratch/research/dx/e8/journal.md`
   (`Predictions (sealed)`): expected expansion shape, adoption count guess
   (of the ~56 `sync_result` lines), expected review ratings, two likeliest
   reviewer misreadings. Commit before any code change
   (`docs(dx-e8): seal predictions`). Never edit afterward.
2. **Docs-first.** Write the doc text for `[%eta.result]` (README section
   alongside `[%eta.sync]`, and the `docs/api-dx.md` leaf-boundary
   guidance) before implementing. Budget ≤ 8 lines to state the contract;
   more means the form is suspect (T8) — note it in your journal.
3. **Implement the smallest change.** Add the `"result"` kind and the
   `Extension.V3.declare "eta.result"` registration; generalize the
   `fail` message so it names the actual form (`[%eta.sync ...]` vs
   `[%eta.result ...]`). Match E7's hygiene: generated identifiers come
   from `__POS__`/`__FUNCTION__` and the use site only.
4. **Gates** (from the worktree, exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo
   ```
   (No JS-track ppx usage exists; the mainline check is conservative.)
   Fix-forward up to three attempts per failure class, then BLOCKED.
5. **Mechanical extras.**
   - Expansion snapshots in `test/ppx_expansion/`: positive case (exact
     contract shape), malformed payloads (non-string name; wrong arity —
     rejection message must name the form, T7 rubric: what/where/what-next).
   - Behavioral parity in `test/ppx_common/ppx_common_suites.ml`: sugar ≡
     hand-written form — same span name, same source location presence,
     `Ok`/`Error`/exception routed identically (in-memory tracer, E7's
     golden pattern).
   - Adoption: convert example leaves per a **stated rule** (write it in
     your journal first — predicted shape: leaves crossing an IO/trust
     boundary get span names; pure glue does not). Count operators per
     leaf boundary before/after (expect 4 → 1 on converted sites).
   - Census table: PPX forms 1 → 2; rejection paths +0; core vals +0.
     Footguns: +0/+0 (state any candidate you notice instead).
6. **Red-team pass** in `.scratch/research/dx/e8/redteam/` with verdicts:
   (a) a body that raises — defect must surface as `Cause.Die` with the
   span, not be swallowed or typed; (b) sugar nested inside an explicit
   `Effect.named` — show the nested-span outcome and document it as
   noisy-but-harmless (or stop and flag if it's actually confusing);
   (c) T9 audit: print the expansion (`snapshot_expansions.sh` output) and
   trace every identifier to the use site or `__POS__`/`__FUNCTION__`.
7. **Review packet** in `.scratch/research/dx/e8/review/`, labeled (the
   orchestrator blinds it): screenshot test — the heaviest converted
   module, `heavy-before.ml` / `heavy-after.ml` (same file, pre/post
   sugar), plus one small `leaf-pair` (single leaf hand-written vs sugar,
   5–10 lines each). `MANIFEST.md`, `QUESTIONS.md` ("what does the sugar
   add beyond `sync_result`?", "where does the span name come from?",
   "what happens if the body raises?").
8. **Report** in `.scratch/research/dx/e8/report.md`: gates summary,
   snapshot/parity evidence, adoption count vs. prediction (scored),
   census/footgun actuals, red-team outcome, deviations, and your
   promote/hold/kill recommendation against the one-pager's gates.

## Done means

Your final message ends with exactly one of:

- `E8 READY FOR REVIEW`
- `E8 BLOCKED: <reason>`
- `E8 STOP: <§4.6 stop condition>`

The orchestrator verifies (diff, focused tests, evidence audit), runs the
independent review, and decides. Rework via follow-up messages.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E8 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E8's surface: `lib/ppx/`, ppx tests, README/`docs/api-dx.md`
  leaf guidance, example conversions. Do NOT touch the deriver's code
  paths (E7) except to share the file cleanly; do not add `[%eta.option]`.
  Adjacent footguns → journal follow-ups, not this diff.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e8/` must be committed.
