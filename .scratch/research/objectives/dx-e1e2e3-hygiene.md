# Objective: DX Phase B batch 1 — E1 `sync_result`/`sync_option` · E2 `discard`/`ignore_errors` · E3 `race_either`

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e1e2e3`
- Branch: `research/dx-e1e2e3-hygiene` (already checked out here; do not create others)
- Phase: B (hygiene) · three experiments, one worktree, sequential sections
- Evidence IDs: `V-DX-E1-*`, `V-DX-E2-*`, `V-DX-E3-*` (orchestrator log); your journal is the branch record

## Executor profile

Three small, fully-specified API changes in one branch: two pure additions
(E1, E3) and one deletion-with-split (E2, breaking — extends the CHANGELOG
idiom-pass entry). Difficulty: care with docs (`docs/api-dx.md` re-pointing
the recommended leaf pattern), the E2 behavior split, and per-experiment
evidence discipline. The Phase A surface (E23–E25) is merged and final —
build on `bind_error`/`fold`/`to_*`, `map_par`, `with_scope`/`named`/
`now_ms`/`error_pp` spellings.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. The most
common action in the library should be one word; the wrong thing should be
unwriteable. North star: *`Effect` is `Result` with concurrency and spans.*

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/eta/effect.mli` — construct cluster (`from_result` /
   `from_option` / `flatten_result` / `sync`), `ignore` / `ignore_errors`,
   `race` (copy its permit-acquisition caveat).
3. `docs/api-dx.md` — the recommended-leaf section you will re-point.
4. `.scratch/research/dx/e24/report.md` and `e25/report.md` — the evidence
   standard to match.
5. If you find any contract below unwritable or unstatable: stop with a
   reproducible probe (the E24 precedent) — do not improvise.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Designs are decided; skip hypothesis-space theatre. Proof obligations per
experiment below.

Working artifacts in `.scratch/research/dx/e1/`, `dx/e2/`, `dx/e3/` **on
this branch** (commit them): each with `journal.md` (or one shared
`journal.md` with clearly separated sections), plus `redteam/` and
`review/` per experiment; one `report.md` per experiment (may be sections
of one file at `.scratch/research/dx/report.md` — your choice, but each
experiment must be independently complete).

## The experiments (from DX-PRD-0001 §E1/E2/E3)

### E1 — `Effect.sync_result` and `Effect.sync_option` (additive)

```ocaml
val sync_result : (unit -> ('a, 'err) result) -> ('a, 'err) t
val sync_option : if_none:'err -> (unit -> 'a option) -> ('a, 'err) t
```

The recommended leaf boundary is currently two combinators deep
(`Effect.sync (fun () -> Db.find id) |> Effect.flatten_result`) — correct
(exception → defect, `Error e` → typed failure, `Ok x` → success) and easy
to forget. The blocking path has `Eta_blocking.run_result`; the sync path
makes users assemble it by hand. No new semantics — implemented as the
composition they name; `flatten_result` stays for hand-rolled cases.
`sync_option` completes the symmetry with `from_option` (same `if_none:`
label). Doc budget ≤ 6 lines each. Docs re-point the recommended pattern;
rewrite the two-combinator leaves in docs/examples to `sync_result` where
they are the recommended shape (81 `flatten_result` lines exist — migrate
only the *recommended-leaf* ones; `flatten_result` stays for the rest).

**Kill/rename gate:** if > 1/3 of persona passes expect `sync_result` to
also catch exceptions, the name teaches the wrong defect model —
`attempt_result` is the fallback; report the misreading evidence raw.

### E2 — `discard` + generalized `ignore_errors` (breaking; CHANGELOG)

```ocaml
val discard : ('a, 'err) t -> (unit, 'err) t
  (* discard success value; ALL causes propagate unchanged *)
val ignore_errors : ('a, 'err1) t -> (unit, 'err2) t
  (* generalized from unit-only: discard value, suppress typed failures *)
```

`Effect.ignore` discards the success value **and suppresses typed
failures**; `Stdlib.ignore` suppresses nothing — the most misleading name
in the surface. Delete `Effect.ignore`; callers split into the two honest
meanings (compiler-guided). `discard` is `map (fun () -> ())`; all causes
propagate. Generalizing `ignore_errors` is source-compatible for correct
uses. Measured: all 7 current `ignore` uses are its own behavior tests —
split them into `discard` tests and `ignore_errors` tests; no production
call sites exist. Extend `CHANGELOG.md`'s idiom-pass entry (it has a
marked extension point for E2).

**Hold gate:** only if migration shows `ignore` was mostly value-discard —
reassess naming, not the split.

### E3 — `Effect.race_either` (additive)

```ocaml
val race_either :
  ('a, 'err) t -> ('b, 'err) t -> ([ `Left of 'a | `Right of 'b ], 'err) t
```

`race` needs a uniform success type; heterogeneous races force
map-wrapping both branches into a common variant. Same loser-cancellation
and resource semantics as `race`; the mli references `race`'s
permit-acquisition caveat verbatim.

**Kill gate:** if reviewers find `` `Left``/`` `Right `` payloads harder to
follow than named variants at call sites.

## Protocol (predictions commit FIRST and separately — all three sections in one commit)

1. **Seal your predictions** in `.scratch/research/dx/journal.md` (or the
   per-experiment journals): per-experiment sections with expected
   teach-back answers, census/footgun deltas, two likeliest reviewer
   misreadings. One commit before any code (`docs(dx-b1): seal
   predictions`). Never edit afterward.
2. **Docs-first** per experiment (`.mli` contracts before implementation),
   then implement the smallest change. Work the experiments **in order
   E1 → E2 → E3**, one commit (or one small commit series) per experiment.
3. **Gates** after each experiment and at the end (exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo lib/http_js
   ```
   (`signal_jsoo` stays pre-broken per F1; do not touch.)
   Fix-forward up to three attempts per failure class, then BLOCKED.
4. **Mechanical extras.**
   - E1: parity tests with `sync |> flatten_result` incl. exception →
     `Die` (`sync_result`) and `None` → typed `if_none` (`sync_option`).
   - E2: behavior tests for `discard` (success discarded; typed failure,
     defect, interruption, finalizer diagnostics all propagate) and
     generalized `ignore_errors` (value discarded, typed failures
     suppressed, everything else visible); the 7 split tests.
   - E3: parity tests with `race` (winner value, loser cancellation,
     finalizer runs).
   - Census table per experiment (predictions: E1 construct +2 vals/+1
     concept; E2 handle −1 val + transform +1 val; E3 concurrency +1
     val/+1 concept). Verify independently.
   - Footgun deltas: E1 −1/+0, E2 −1/+0, E3 +0 (predicted).
   - `docs/api-dx.md` re-pointed to `sync_result` as the recommended leaf —
     explicit checklist item.
5. **Red-team pass** per experiment, committed with verdicts:
   - E1: call `sync_result` expecting it to convert a raised exception
     into a typed failure — show it becomes `Die` (the name must not
     invite the attempt-model).
   - E2: write the swallowed-error bug the old `ignore` invited — show it
     now requires the explicit `ignore_errors`, visible in a diff.
   - E3: a heterogeneous race with the map-wrapped workaround vs
     `race_either` — is anything still clearer about the workaround?
6. **Review packet** in `.scratch/research/dx/review/`, labeled: three
   A/B pairs, 10–30 lines each — (a) E1: DB-lookup leaf, two-combinator
   vs `sync_result`; (b) E2: a fire-and-forget cleanup, old `ignore` vs
     the honest split (show both new spellings where both meanings occur);
   (c) E3: timeout-vs-result race, map-wrapped vs `race_either`.
   `MANIFEST.md`, `QUESTIONS.md` ("does `sync_result` catch exceptions?",
   "what does `discard` do to typed failures?", "what does `ignore_errors`
   do to defects?", "which `` `Left `` is which?").
7. **Reports**: per experiment — gates summary, evidence, census/footgun
   actuals vs. sealed predictions (scored), red-team outcome, deviations,
   and a promote/hold/kill recommendation against its one-pager's gates.

## Done means

Your final message ends with exactly one status line per experiment:

- `E1 READY / E2 READY / E3 READY` (each possibly `BLOCKED: <reason>` or
  `STOP: <§4.6 condition>` instead)

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E1/E2/E3 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it plainly untracked — do NOT gitignore it).
- Stay in E1/E2/E3's surface. Adjacent footguns → journal follow-ups.
- `objective.md` stays uncommitted; everything under `.scratch/research/dx/`
  must be committed.
