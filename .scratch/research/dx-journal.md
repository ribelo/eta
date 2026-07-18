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

---

## V-DX-E24-001 — 2026-07-18 — research/dx-e24-iteration-mirrors-list — phase: predict (orchestrator-sealed)

Sealed before the branch existed. Scored at V-DX-E24-002.

**Current shapes (measured pre-change).** Iterate cluster in `effect.mli`:
`for_each_par` (44 call-site lines), `for_each_par_bounded` (91),
`retry` (90, schedule-first positional, 3-param Schedule), `retry_or_else`
(23), `repeat` (17). `Schedule.t` is `('input, 'output, 'hook) t`; `driver`
and `step` types also carry the third param; `no_hook = |` exists solely to
plug it. Tap usage outside `schedule.ml`: 16 lines, all in 3 test files —
no lib/examples/bench uses. JS-track call sites exist in
`test/cache_jsoo`, `test/js_jsoo`, `test/signal_jsoo` (checked lib AND
test dirs this time — E23 lesson).

**Census (predicted).** Iterate cluster 5 vals → 3 (`map_par`, `retry`,
`repeat`); concepts 5 → 2 (parallel map; schedule-driven repetition).
`Schedule.t` 3 params → 2 across `t`, `driver`, `step` and every
combinator; `no_hook` deleted; `tap_input`/`tap_output` deleted from the
public API (16 test lines migrate to `?on_retry`/`?on_repeat` observers).
Footguns: **−2/+0** ("`for_each` collects results" name/type mismatch;
`retry`/`retry_or_else` duplication).

**Migration size (predicted).** ~265 iterate call-site lines + ~30
`Schedule.t` type mentions; 60–90 files including 3 jsoo test files.

**Teach-back / guess-the-semantics (P-OCaml, predicted).**
- `?max_concurrent` → "at most N running at once, rest queue" — correct.
- `map_par` result order → "input order, like `List.map`" — correct.
- sibling fate on failure → "fail-fast, others cancelled" — correct.
- `~while_` → "predicate deciding whether to retry a typed failure" —
  correct from name+type; one possible misread as a success-loop.

**Persona mistakes (two each, predicted).**
- P-OCaml: (1) expects `?max_concurrent` default to be finite (CPU count),
  not unbounded; (2) first reads `while_` as "repeat while this holds on
  success" (loop intuition) before the type corrects them.
- P-ZIO: (1) expects `retry` to retry all failures without a required
  `~while_` (ZIO defaults) — friction; (2) expects observers to be able to
  alter the schedule decision (ZIO schedules are effectful values);
  surprised they are observe-only.
- P-Maint: (1) expects observer failures to be swallowed rather than
  failing the typed channel (mli must state it); (2) suspects `?or_else`
  receiving `None` on first-rejection is a behavior change vs.
  `retry_or_else` (it is not — preserved).

**Review (predicted).** Blind A/B (bounded-parallel fetch;
retry-with-fallback): new median ≥ 4 with no rating ≤ 2; old
(`for_each_par_bounded`; positional `retry_or_else`) median ≤ 3. Risk
point: the `while_` underscore label — predicted accepted as OCaml
keyword-avoidance idiom, possibly one grumble, no rating drop below 4.

**Outcome (predicted).** Promote. The Schedule-slimming hold trigger
("uses observers cannot express") does NOT fire — taps are test-only and
all 16 uses map to observers. Gates green within three fix attempts;
mainline jsoo compile check on `cache_jsoo`/`js_jsoo` (`signal_jsoo`
pre-broken per F1 — verify unchanged, do not fix).

---

## V-DX-E24-002 — 2026-07-18 — research/dx-e24-iteration-mirrors-list — phase: orchestrator decision (contract amendment + scope reduction)

Executor reported `E24 BLOCKED` with reproducible evidence
(`.scratch/research/dx/e24/report.md`, `contract-blocker/probe.sh`) before
any production edit. Both claims verified independently by the orchestrator.

**Finding 1 — the one-pager's signatures are unwritable in OCaml.**
Optional arguments cannot be erased when they are the last arrows in the
type (Warning 16): `map_par ids ~f` against the proposed type returns
`?max_concurrent:int -> ('b list, 'err) t`, a partial application, not an
effect. The plan's sketch treated OCaml optionals like named parameters.
Amendment (orchestrator authority, taste): optionals move before a trailing
mandatory argument —

```ocaml
val map_par :
  ?max_concurrent:int -> 'a list -> f:('a -> ('b, 'err) t) -> ('b list, 'err) t
val retry :
  schedule:('err, 'out) Schedule.t -> while_:('err -> bool) ->
  ?or_else:('err -> 'out option -> ('a, 'err) t) ->
  ('a, 'err) t -> ('a, 'err) t
val repeat :
  schedule:('a, 'out) Schedule.t ->
  ('a, 'err) t -> ('out, 'err) t
```

`map_par` mirrors `List.map : 'a list -> f:` with the optional prepended;
`retry`/`repeat` become data-last (pipeline-native, matching today's
positional use). Erasure verified by the same probe discipline.

**Finding 2 — the `Schedule.t` slimming hold trigger fired.** `Resource.auto`
(`lib/eta/resource.mli:12-29`, `resource.ml:90-110`) publicly accepts and
drives hook-bearing schedules in its refresh daemon; the behavior is encoded
in `test/core_common/resource_common_suites.ml`. E24's observers live on
`retry`/`repeat` and cannot cover a hand-rolled driver. Per the one-pager's
pre-registered gate: **the slimming holds; the renames promote.**
Consequences: `Schedule.t` stays 3-param with `tap_input`/`tap_output`;
`retry` keeps the effect-instantiated hook parameter as today; `?on_retry`/
`?on_repeat` observers are NOT added this round (T1 — taps remain the single
observation mechanism while they exist).

**Follow-up registered: E24b** — "Resource.auto observer contract +
Schedule.t slimming". Entry gate: a decided observer contract for
`Resource.auto` (e.g. `?on_step`), after which slimming is reconsidered.
Added to the programme backlog; phase assignment at the Phase A synthesis.

**Prediction scoring (orchestrator, V-DX-E24-001).** Miss: "the slimming
hold trigger does NOT fire — taps are test-only" — wrong; the tests encode
`Resource.auto`'s public behavior. Executor's own sealed prediction (that
slimming should hold if a non-expressible tap use appears) was the sharper
read. Runtime/census/footgun predictions rescoped by this amendment and
scored at E24 completion.

**Protocol note.** The executor did exactly what the method asks: stopped
at the contract boundary, reproduced with a runnable probe, recommended,
changed nothing. This is the evidence-based-coding loop working as designed.

---

## V-DX-E24-002a — 2026-07-18 — correction to V-DX-E24-002

The signature block in V-DX-E24-002 shows `retry` with
`schedule:('err, 'out) Schedule.t` — the 2-param type. That contradicts the
same entry's Finding 2 (slimming held). Correct amended contract for the
resumed, rescoped E24:

```ocaml
val map_par :
  ?max_concurrent:int -> 'a list -> f:('a -> ('b, 'err) t) -> ('b list, 'err) t

val retry :
  schedule:('err, 'out, (unit, 'err) t) Schedule.t ->
  while_:('err -> bool) ->
  ?or_else:('err -> 'out option -> ('a, 'err) t) ->
  ('a, 'err) t -> ('a, 'err) t

val repeat :
  schedule:('a, 'out, (unit, 'err) t) Schedule.t ->
  ('a, 'err) t -> ('out, 'err) t
```

`Schedule.t` stays 3-param; `tap_input`/`tap_output` stay; no `?on_retry`/
`?on_repeat` this round. Migration wrinkle the executor must document: the
unified `retry` has a single `'err`; old `retry_or_else` could remap the
error channel (`'err1 -> 'err2`) — affected call sites need an explicit
`map_error` composition, listed one by one in the executor journal. If any
call site cannot be expressed this way, that is a fresh BLOCKED signal.

---

## V-DX-E24-003 — 2026-07-18 — research/dx-e24-iteration-mirrors-list — phase: orchestrator decision (final contract after oracle consultation)

Two-round adversarial consultation with the oracle; consensus reached. This
entry SUPERSEDES the E24 contract parts of V-DX-E24-002/002a where they
conflict (single-`'err` unification, list-first `~f` map_par, E24b framed as
a `Resource.auto` callback design). Oracle factual claims verified in code
before concession: `for_each_par` = `min n 8` workers; `retry` matches bare
`Cause.Fail` only while `retry_or_else` handles composite causes;
`Schedule.step_plan` public; `Effect.map` function-first unlabeled;
`Eta_stream` ×4 public hook-schedule operations.

**Final E24 contract (consensus).**

```ocaml
val map_par :
  ?max_concurrent:int -> ('a -> ('b, 'err) t) -> 'a list -> ('b list, 'err) t
  (* absorbs for_each_par + for_each_par_bounded, both deleted;
     absent max_concurrent = 8, documented (today's silent min n 8);
     Invalid_argument on max_concurrent <= 0 at construction *)

val retry :
  schedule:('err, 'out, (unit, 'err) t) Schedule.t ->
  while_:('err -> bool) -> ('a, 'err) t -> ('a, 'err) t

val retry_or_else :
  schedule:('err1, 'out, (unit, 'err2) t) Schedule.t ->
  while_:('err1 -> bool) ->
  or_else:('err1 -> 'out option -> ('a, 'err2) t) ->
  ('a, 'err1) t -> ('a, 'err2) t

val repeat :
  schedule:('a, 'out, (unit, 'err) t) Schedule.t ->
  ('a, 'err) t -> ('out, 'err) t
```

Key decisions:

1. **`retry_or_else` KEPT.** The two-error form is genuine typed-error
   expressiveness; `map_error` cannot recover it (schedule would see the
   wrong type; fallback would lose the schedule output; no
   information-preserving map need exist). The "duplication" the one-pager
   diagnosed was misdiagnosed — the two operations also differ in cause
   semantics today.
2. **The cause-semantics divergence is documented as a current limitation,
   not canonized.** mli states the difference explicitly; a separate
   semantic decision is registered: should `retry` adopt
   `retry_or_else`'s catchable typed-cause semantics? (backlog)
3. **`map_par` is function-first** — Stdlib `List.map` and Eta's own
   `Effect.map`, not Base/Core's `~f`-labeled list-first. Optional
   prepended; erasure probe required.
4. **Default 8 is honest and tested** (test with >8 inputs proves the
   cap), turning hidden behavior into an intentional contract.
5. **`Schedule.t` untouched** — 3 params, taps, `no_hook` stay; no
   `?on_retry`/`?on_repeat` anywhere.
6. **E24b reframed:** "Schedule-hook ownership: policy vs. driver".
   Inventory must cover `Effect.retry`, `retry_or_else`, `repeat`,
   `Resource.auto`, `Eta_stream` ×4, and the full public driver protocol —
   `start`, `driver`, `step`, `step_plan`, `step_with_hooks`, `next`,
   `no_hook` — evaluating the existing `step_with_hooks` seam before
   inventing per-driver callbacks. Semantics matrix: pre/post-step,
   terminal `Done`, hook failure, state advancement. "Retain hooks and
   close the slimming permanently" is a live outcome.

Rescoped predictions: iterate cluster 5 → 4 vals / 5 → 4 concepts;
footguns −1/+0; migration ~265 call lines (for_each_par×2 ~135 + labeled
retry/repeat call-site updates ~130), mechanical. Executor resumes on the
same branch with follow-up objective `followup-1.md`.
