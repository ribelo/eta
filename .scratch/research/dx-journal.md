# DX programme journal (V-DX-*)

Programme log for DX-PRD-0001 (`dx-prd-0001.md`, same directory). Append-only:
corrections are new entries referencing old ones. Orchestrator-sealed
predictions land here on master before each experiment branch is cut;
executors seal their own predictions in their branch journals. The legacy
`.scratch/research/journal.md` is frozen history; this file is the live
record. Durable curated conclusions land in `docs/research/dx.md`.

## Dashboard (copy of DX-PRD-0001 §6; both updated after every experiment)

| ID | Title | Phase | Effort | Risk | Status | SC | Branch | Evidence |
|----|-------|-------|--------|------|--------|----|--------|----------|
| E23 | Error channel mirrors Result | A | M | low | **promoted** | SC | research/dx-e23-result-error-channel | V-DX-E23-001..002 |
| E24 | Iteration mirrors List; slim Schedule | A | M | low-med | proposed | | | |
| E25 | Family consistency renames | A | S-M | low | proposed | | | |
| E1 | sync_result / sync_option | B | S | low | proposed | | | |
| E2 | discard / ignore_errors | B | S | low | proposed | | | |
| E3 | race_either | B | S | low | proposed | | | |
| E4 | Cause rendering corpus | B | M | low | proposed | | | |
| E5 | Type-error translations | B | S | low | proposed | | | |
| E6 | Scoped.with_2/3 (kills and@) | B | M | low | proposed | | | |
| E7 | Error-pp deriver | C | M | low | proposed | | | |
| E8 | [%eta.result] sugar | C | S | low | proposed | | | |
| E9 | Syntax.Parallel/Applicative | C | M | med | proposed | | | |
| E10 | let%eta function sugar | C | M | med | proposed (hold default) | | | |
| E26 | Effect.fresh | D | S | low | proposed | | | |
| E19 | Scoped capability override | D | M | med | proposed | | | |
| E20 | intercept_log/metric | D | M | low-med | proposed | | | |
| E11 | Eta_test.run golden record | D | L | med | proposed | | | |
| E12 | audit / describe | D | M | low | proposed | | | |
| E13 | Effect.async | D | M-L | med | proposed | | | |
| E14 | Eta.Promise | D | M | med | proposed (hold-gated) | | | |
| E22 | Law-property policy | E (flex) | M | low | proposed | | | |
| E15 | interruptible / restore | E | M | high | proposed | | | |
| E16 | Reader validation race | E | S | low | proposed (expected kill) | | | |
| E21 | Resumable probe (.scratch) | E | S | contained | proposed (expected kill) | | | |
| E17 | Capability phantom rows | E | L | high | proposed (gated) | | | |
| E18 | Simulation testing | E | L | med | proposed | | | |

---

## V-DX-000 — 2026-07-18 — programme start

DX-PRD-0001 adopted from the executor-facing draft with Amendment 1:
human-relayed topology (orchestrator / intermediary / executor), three-tier
journal architecture, dual-sealed predictions, oracle-based blind review with
a fixed persona (P-OCaml default per experiment, others per one-pager),
sequential execution with orchestrator-discretion batching. The human's
instructions outrank the plan. Taste constitution §2 and stop conditions §4.6
unchanged. Git: orchestrator manages master, branches, and pushes.

Protocol notes for future readers: agent-run persona evidence is labelled
`[agent-sim]`; promote decisions resting solely on it are flagged
`spot-check`. Blind-review packets are assembled and randomized by the
orchestrator from executor-labeled material; the oracle never sees labels,
goals, or implementations.

---

## V-DX-E23-001 — 2026-07-18 — research/dx-e23-result-error-channel — phase: predict (orchestrator-sealed)

Sealed before the branch existed. Scored at V-DX-E23-002 against the
executor's own branch-journal predictions and the measured results.

**Walkthrough expectations (W1 is the channel task).** Post-change W1 path:
`Effect.sync (fun () -> Db.find id) |> Effect.flatten_result |>
Effect.bind_error (fun `Not_found -> Effect.pure default)`. A reviewer
reading the call site names the channels correctly: `Error` → typed failure
channel, exception → defect, `bind_error` touches only the typed channel.

**Teach-back (plan-mandated prediction).** "What does `bind_error` do to
defects?" answered correctly by 3/3 persona passes without a doc lookup
("nothing — they propagate; it binds the typed error channel like
`Result.bind_error`"). Baseline with `catch`: at least one persona guesses
"catches exceptions".

**Blind A/B (W1 snippet, old vs. new naming).** Old (`catch`) median 3,
with ≥1 reviewer misreading the defect behavior; new (`bind_error`) median
≥4, zero defect misreadings. `fold ~ok ~error` reads as `Result.fold` —
one reviewer may ask whether handlers are pure (they are); predicted as a
question, not a rating drop below 4.

**Persona mistakes (two each, predicted).**
- P-OCaml: (1) reaches for `to_result` + `Result` pattern-match instead of
  `bind_error` out of Stdlib habit; (2) briefly expects `fold` to see
  defects, reads "both channels" as "all causes".
- P-ZIO: (1) hunts for `catchAll`/`catchAllCause`, misjudges their absence;
  (2) tries to return effects from `fold` handlers (`foldZIO` habit) and
  hits the pure-handler type error.
- P-Maint: (1) assumes `to_result` and `to_exit` reify the same things —
  predicts confusion about which one captures defects (`to_exit` does,
  `to_result` doesn't); (2) expects `catch_some` to have been renamed too
  and searches for a nonexistent new name.

**Census (measured pre-change).** Handle cluster in `effect.mli`: 11 public
vals (`catch`, `catch_some`, `recover`, `or_else`, `or_else_succeed`,
`ignore_errors`, `ignore`, `result`, `option`, `exit`, `map_error`), 10
concepts. Post-change: 10 vals, 8 concepts (`recover` + `or_else_succeed`
merge into `fold`). All other clusters flat.

**Migration size (measured).** ~51 source files, ~220 call-site lines
(`catch` 149, `exit` 26, `recover` 18, `result` 10, `catch_some` 5,
`option` 4, `or_else` 4, `or_else_succeed` 3, `ignore` 7), plus `README.md`
and 3 docs pages. No JS-track call sites; jsoo gates not required.

**Footguns.** −1: the top trap "`catch` catches exceptions" is removed by
construction. +0 expected.

**Outcome.** Promote. Gates green within three fix attempts. Risk points:
(1) `fold`'s `('b, 'outer) t` return type draws one reviewer question;
(2) `docs/api-dx.md` consistency is the easiest migration step to forget —
flagged as an explicit verification item.

---

## V-DX-E23-002 — 2026-07-18 — research/dx-e23-result-error-channel — phase: results + decision

**Gates** (orchestrator re-run, independent of executor claims): `build
@install` pass · `runtest --force` pass · `eta-oxcaml-test-shipped` pass —
in the worktree, and again on master after the `--no-ff` merge. Mainline
jsoo spot-check: `test/http_js` + `test/js_jsoo` compile clean;
`test/signal_jsoo` fails identically on master (pre-existing OxCaml-syntax
bit-rot in `lib/signal` — not caused by, and not blocking, E23; logged as
follow-up F1).

**Migration.** Zero stale references to deleted spellings in code or docs
(orchestrator `rg` audit). 84 files changed (953+/420−). `fold` is exactly
the contracted composition. `catch_some`/`or_else` kept per one-pager.
Third commit records the executor catching its own over-rename of
effect-TS code in the TS bench — good self-correction.

**Blind review** `[agent-sim, spot-check]` (oracle, fresh context, P-OCaml
persona, snippets blinded+randomized by orchestrator, key sealed outside
packet): ratings new **4,4,4** (median 4) vs old **3,3,1** (median 3);
pass bar met. Cold reads: 3/3 correct channel identification on new names;
`catch` misread as exception-catcher on a cold read (rated **1** — "the
exact bug this API invites"). Vocabulary teach-back: `to_result`/`to_exit`
distinction answered correctly from names alone; bare `result`/`exit`
flagged as ambiguous. Preferences: new in all 3 pairs. Caveat, raised
independently by oracle and executor: `fold ~ok:Fun.id` is boilerplate next
to the deleted `recover` — ergonomics, not comprehension; logged as
follow-up F2.

**Teach-back** (plan pass bar: correct without doc lookup): 3/3 cold-read
answers correct on new naming. Hit.

**Red-team:** `bind_error` used as `try/with` to swallow a `failwith` →
defect surfaces via `Cause.Die`, handler never ran
(`.scratch/research/dx/e23/redteam/`). Runtime boundary intact; the
inviting *vocabulary* is gone.

**Census:** handle cluster 11 → 10 vals, 10 → 8 concepts. The concept
count reassigns `map_error` to the transform cluster — disclosed by the
executor; accepted as the cluster definition going forward. **Footguns:**
−1/+0 ("catch catches exceptions" removed by construction).

**Prediction scoring (orchestrator, V-DX-E23-001).** Hits: teach-back 3/3;
old median 3 with a defect-misreading; new median ≥4; census vals and
concepts; footguns; gates green ≤3 attempts; promote outcome. Miss:
migration size — predicted ~51 source files, actual 84 (undercounted
bench/docs/http-testsuite ripple). Untested: P-ZIO/P-Maint predictions
(single-persona review). **Executor predictions:** mostly hit; one factual
miss — "no JS-track call sites found" (3 JS test files carried deleted
spellings; migrated but unflagged; journal/report claim was inaccurate).
Orchestrator made the same wrong claim in its pre-flight check. Both
recorded; neither affected the outcome (mainline compile check passed for
the affected packages).

**Protocol deviations (accepted):** executor batched protocol steps 2–8
into two commits after the sealed-predictions commit (sealing order
preserved; granularity coarser than the objective asked).

**Decision: PROMOTE.** Merged `--no-ff` (`66bad437`); master gates green;
master and branch pushed. Worktree removed; branch kept as provenance;
objective archived at `.scratch/research/objectives/dx-e23-result-error-channel.md`.

**Follow-ups:**
- F1: `test/signal_jsoo` + `lib/signal` JS-track breakage pre-exists on
  master (OxCaml-only syntax in `.mli`). Owner: next JS-track experiment
  or a dedicated fix; flagged in the dashboard.
- F2: `fold ~ok:Fun.id` boilerplate for pure recovery-only sites (oracle +
  executor). Watch item: if Phase B usage data shows the pattern is hot,
  bring evidence to the idiom-pass discussion instead of re-adding
  `recover` by taste.
- F3: `examples/catch_recovery.ml` filename keeps the old noun (id is
  referenced by `test/api_dx`). Cosmetic; revisit with E5's docs work.
