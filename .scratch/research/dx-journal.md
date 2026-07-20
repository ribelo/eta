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
| E24 | Iteration mirrors List; slim Schedule | A | M | low-med | **promoted** (slimming held → E24b) | SC | research/dx-e24-iteration-mirrors-list | V-DX-E24-001..004 |
| E25 | Family consistency renames | A | S-M | low | **promoted** | SC | research/dx-e25-family-consistency | V-DX-E25-001..002 |
| E1 | sync_result / sync_option | B | S | low | **promoted** 2026-07-18/20 (sync_option reversal by human authority) | SC | research/dx-e1e2e3-hygiene | V-DX-E1-001..004 |
| E2 | discard / ignore_errors | B | S | low | **promoted** | SC | research/dx-e1e2e3-hygiene | V-DX-E2-001..002 |
| E3 | race_either | B | S | low | **killed** (named variants win) | SC | research/dx-e1e2e3-hygiene | V-DX-E3-001..002 |
| E4 | Cause rendering corpus | B | M | low | **promoted** 2026-07-19 (kill gate fired; rework passed) | SC | research/dx-e4e5-cause-corpus-type-errors | V-DX-E4-001..002 |
| E5 | Type-error translations | B | S | low | **promoted** 2026-07-19 | SC | research/dx-e4e5-cause-corpus-type-errors | V-DX-E5-001..002 |
| E6 | Scoped.with_2/3 (kills and@) | B | M | low | **killed** (helpers) · recipe promoted 2026-07-19 | SC | research/dx-e6-scoped-with-helpers | V-DX-E6-001..002 |
| E7 | Error-pp deriver | C | M | low | **promoted** 2026-07-19 | SC | research/dx-e7-error-pp-deriver | V-DX-E7-001..002 |
| E8 | [%eta.result] sugar | C | S | low | **promoted** 2026-07-19 | SC | research/dx-e8-eta-result-sugar | V-DX-E8-001..002 |
| E9 | Syntax.Parallel/Applicative | C | M | med | **held** 2026-07-19 (baseline 2/6, explicit 2/6) | SC | research/dx-e9-syntax-parallel-applicative | V-DX-E9-001..002 |
| E9b | Honest and* (sequential); Effect.par | C | S-M | low-med | **promoted** 2026-07-19 | SC | research/dx-e9b-honest-and-star | V-DX-E9B-001..002 |
| E10 | let%eta function sugar | C | M | med | **held** (let%eta killed; [@@eta.trace] pre-selected, trigger defined) | SC | research/dx-e10-function-sugar | V-DX-E10-001..002 |
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

---

## V-DX-E24-004 — 2026-07-18 — research/dx-e24-iteration-mirrors-list — phase: results + decision

**Gates** (orchestrator re-run): native trio pass in worktree AND on master
after the `--no-ff` merge (`29bd23e9`); mainline `test/cache_jsoo` +
`test/js_jsoo` compile clean; `signal_jsoo` failure confirmed identical to
master (executor compared against a master archive — six syntax diagnostics
+ one type error, same files/lines).

**Contract.** Verified verbatim against V-DX-E24-003: `map_par
?(max_concurrent = 8) f xs` function-first with `min max_concurrent n`
workers and construction-time `invalid_arg`; `retry`/`retry_or_else`/
`repeat` labeled data-last; `retry_or_else` two-error form retained;
`Schedule.t` 3-param with taps untouched. mli documents the default cap
("the default is 8") and the retry cause-divergence as a *current
limitation* (not canonized) with cross-references both ways; bonus:
`map_par`'s doc fences the fibers-vs-domains confusion (`eta_par`).

**Parity suite** (all green in orchestrator re-run): omission yields
`Effect.t` (the original blocker, now a test); mapper lazy at blueprint
construction (defect at runtime, capped too); input order under out-of-order
completion; fail-fast; finalizer cancellation parity; explicit cap
enforcement; **default cap 8 proven with 9 inputs**; nonpositive rejection;
`or_else` `None`/latest-`Some`/terminal-`Some`; composite first-typed-
failure; tap behavior under new call shapes.

**Red-team:** nonpositive bounds (0, −3) fail loudly at construction;
omission *looks* unbounded but measures peak 8 — verdict honestly notes the
call site alone cannot communicate the cap and the docs sentence is load-
bearing. No overclaiming.

**Independent review** `[agent-sim, spot-check]` (oracle, fixed P-OCaml
persona, randomized blinded pairs): par pair — `map_par` **5** vs
`for_each_par_bounded` **3**; retry pair — labeled data-last **4** vs
positional **3**. Cold reads: order, `~while_` rejection→`None`, fallback
error-type change all correct; composite-cause handling correctly judged
undecidable-from-call-site (documented in mli). One misreading: omitted
bound guessed as unbounded — the exact failure the mli sentence +
`docs/api-dx.md` note + default-cap test address. Preferences: new in both
pairs; winner's weakness noted (`map_par` doesn't advertise boundedness like
`_bounded` did — accepted, documented).

**Census/footguns:** iterate cluster 5 → 4 vals / 5 → 4 concepts (verified
independently); `Schedule.t` unchanged (3 params, 2 tap vals); zero stale
references; footguns −1/+0.

**Prediction scoring.** Orchestrator V-DX-E24-001: hits — order, fail-fast,
`~while_` reads, review medians (new ≥4/no ≤2 vs old ≤3), promote outcome;
misses — census targets (superseded by rescope), slimming-trigger
prediction (fired; recorded at V-DX-E24-002), omission-misreading direction
(predicted "expects finite default"; actual guess was "unbounded" — the
red-team's caveat matters more than my guess). Executor: original set
mostly superseded/missed by rescope (scored honestly); amendment set all
hit.

**Protocol compliance:** dual-sealed predictions (two executor sets,
commit-verified before code); docs-first commit order; blocked-at-contract
handled per method; rework via follow-up objective; assignment files
uncommitted; `signal_jsoo` verified unchanged via master-archive
comparison. Clean.

**Decision: PROMOTE** (amended contract). Merged `--no-ff` (`29bd23e9`),
master gates green, master + branch pushed, worktree removed, objectives
archived (incl. `dx-e24-followup-1.md`). The `Schedule.t` slimming remains
**held** and registered as E24b ("hook ownership: policy vs. driver";
inventory: `Effect.retry`/`retry_or_else`/`repeat`, `Resource.auto`,
`Eta_stream` ×4, full driver protocol incl. `step_with_hooks`; "retain
hooks permanently" is a live outcome). Also registered: retry
cause-semantics alignment decision (should `retry` adopt composite-cause
handling?) — both land in the programme backlog at the Phase A synthesis.

**Follow-ups carried:** F1 signal_jsoo bit-rot; F2 `fold ~ok:Fun.id` noise;
F3 `catch_recovery.ml` filename. New: F4 omission-vs-unbounded misreading —
mitigated by mli sentence + api-dx note + default-cap test; watch whether
users read it (candidate input for E5's translation page).

---

## V-DX-E25-001 — 2026-07-18 — research/dx-e25-family-consistency — phase: predict (orchestrator-sealed)

Sealed before the branch existed. Scored at V-DX-E25-002.

**Current shapes (measured).** `scoped` (114 call lines) is the only
non-`with_*` member of an 8-strong lifecycle family (`with_resource`,
`with_resource_exit`, `with_background`, `with_error_renderer`,
`with_result_attrs`, `with_external_parent`, `with_context`,
`with_minimum_log_level`). `named` (271) + `named_kind` (23) duplicate one
concept; `named_kind`'s `kind:` is required, which is why the pair exists.
`now` (21) returns raw int ms. `with_error_renderer` (10) + `?error_renderer`
params on `fn`/`named` (50 mentions) demand `('err -> string)`, forcing
`Format.asprintf "%a" pp_err` per module. Proposed `named ?kind ?error_pp
string eff` is erasure-safe (optionals followed by two mandatory args —
E24 lesson applied). JS track: call sites in `test/js_jsoo` ×2 and a doc
xref in `lib/jsoo/eta_jsoo.mli`.

**Census (predicted).** Observability cluster −1 val (`named_kind`
absorbed); lifecycle cluster flat (`scoped` → `with_scope`, family becomes
uniform); clock rename `now` → `now_ms`; `?error_renderer` → `?error_pp`
on `fn`/`named`; `with_error_renderer` → `with_error_pp`. Deletions:
`scoped`, `named_kind`, `now`, `with_error_renderer`. Footguns: −1/+0
(two-`named` guess-which-one removed; `now`'s unit-free int is a minor
trap also removed — call it −1 to −2, seal **−1** conservatively).

**Migration size (predicted).** ~490 call-site lines across ~60–100 files,
overwhelmingly mechanical; JS compile check required on `test/js_jsoo`.

**Teach-back (predicted).** "Which combinator opens a resource scope?" —
`with_scope` answered instantly (baseline `scoped`: hesitation). 3/3.

**Review (predicted).** A/B of the four call sites: new median ≥ 4, no
rating ≤ 2. Risk points: (1) `error_pp`'s `Format.formatter -> 'err -> unit`
shape — predicted read correctly by Format culture (`pp` convention);
(2) `with_error_pp` shortening "renderer" to "pp" — one possible grumble
about jargon, no rating below 4.

**Persona mistakes (two each, predicted).**
- P-OCaml: (1) reads `error_pp` output as user-facing text rather than
  telemetry; (2) expects `with_scope` to hand a scope handle
  (`Eio.Switch.run (fun sw -> ...)` shape) rather than wrap an effect.
- P-ZIO: (1) looks for where the `Scope` value comes from (ZIO's
  environment `Scope`); (2) expects `now_ms` to return a time type, not
  raw int — actually the rename makes the raw-ness honest; predicted read
  correctly.
- P-Maint: (1) expects a raising `error_pp` to be a defect via the ordinary
  capture path (it is — documented); (2) worries about double-rendering
  (contract: at most once per span status/exception event).

**Outcome (predicted).** Promote wholesale; no per-rename revert. One
golden span-status test rendering via `error_pp` (T6 socket for E7).
Gates green within three fix attempts.

---

## V-DX-E25-002 — 2026-07-18 — research/dx-e25-family-consistency — phase: results + decision

**Gates** (orchestrator re-run): native trio pass in worktree AND on master
after the `--no-ff` merge (`eac6d482`); mainline `test/js_jsoo` + `lib/jsoo`
compile clean; `signal_jsoo` untouched per F1.

**Contract.** Verified: `scoped` → `with_scope`; `named_kind` absorbed into
`named ?kind ?error_pp` (erasure-safe — omission probe proves all four
omission shapes yield `Effect.t`); `now` → `now_ms`; `with_error_renderer`/
`?error_renderer` → `with_error_pp`/`?error_pp` (`Format.formatter -> 'err
-> unit`). Render-once via memoization by physical identity; a raising pp
becomes a defect through the ordinary capture path — the silent
`"<error renderer raised>"` fallback is deleted (per one-pager contract and
the break-loudly rule; disclosed in the executor's deviations). Internal
frame field keeps the `error_renderer` name — private representation,
disclosed, accepted. `Supervisor.scoped` intentionally unchanged; logged as
adjacent follow-up F5.

**Golden tests** (green in orchestrator re-run): domain string in span
status; render-once (counter == 1); raising pp → defect; optional-omission
erasure.

**Red-team:** raising-pp defect path proven (exit is `Die`, span closes
honestly); `named`/`named_kind` dual-verb bug unwriteable post-merge.

**Independent review** `[agent-sim, spot-check]` (oracle, fixed P-OCaml
persona, blinded pairs, advocating prose stripped): pair A — `with_scope` +
merged `named` **4** vs old **3** ("reads as opening a delimited region";
`scoped` "less explicit"); pair B — `error_pp` **4** vs `error_renderer`
**4**, preference to new on the decisive argument (composes with existing
`pp` printers vs. needing `Format.asprintf`). Teach-back: scope combinator
identified correctly both sides, faster and more confident on `with_scope`;
`now_ms` "at least establishes milliseconds… better, though still
insufficient" (wall-vs-monotonic carried by the mli sentence). Caveats
logged: "scope" could read as structured-concurrency (family context
disambiguates); `pp` abbreviation "less discoverable" (Format culture
accepted).

**Census/footguns:** observability cluster −1 val (`named_kind`); lifecycle
family uniform `with_*`; zero stale public refs; footguns −1/+0 (verified
independently).

**Prediction scoring.** Orchestrator V-DX-E25-001: hits — census, footguns,
review medians, `error_pp` Format-culture read, `pp`-grumble-without-drop,
promote outcome; partial — `now_ms` read (monotonic honesty needed the mli
sentence, as expected, but "read correctly" was optimistic: reviewer still
guessed wall-clock first); untested — P-ZIO/P-Maint specifics (single-
persona review). Executor: 7 hits, 1 partial (their report).

**Protocol compliance:** predictions sealed pre-code (commit order
verified); gates green; scope discipline; assignment file handled.
Deviation: executor `.gitignore`d the objective file rather than leaving it
plainly untracked — harmless; noted for future objectives (prefer plain
untracked).

**Decision: PROMOTE all four renames.** Merged `--no-ff` (`eac6d482`),
master gates green, master + branch pushed, worktree removed, objective
archived. Phase A complete — synthesis at V-DX-PHASE-A.

---

## V-DX-PHASE-A — 2026-07-18 — Phase A synthesis (idiom pass)

**What the evidence says.** Three experiments promoted (E23 `66bad437`,
E24 `29bd23e9`, E25 `eac6d482`); master gates green after every merge and
now. Cumulative census: handle cluster 11→10 vals / 10→8 concepts
(V-DX-E23-002); iterate cluster 5→4 / 5→4 (V-DX-E24-004); observability −1
val; lifecycle family uniform `with_*` (V-DX-E25-002). Cumulative footguns:
**−3/+0**. Independent reviews (fixed P-OCaml persona, blinded randomized
pairs): new shapes rated 4,4,4 / 5,4 / 4,4 vs old 3,3,1 / 3,3 / 3,4 — every
pair preferred new; the two most-cited old-side failures (`catch` →
try/with misreading, rated 1; `for_each` not promising a collected ordered
result) are gone by construction. The north-star sentence — *`Effect` is
`Result` with concurrency and spans* — is now literally true in the mli for
the error channel and iteration. `CHANGELOG.md` created with the single
"idiom pass" entry as the migration guide (extends with E2/E9).

**Wrong predictions and their lessons.**
- Orchestrator: E23 migration size (~51 → actual 84 files — census your
  blast radius with the same rg patterns you predict against). E24
  slimming-trigger ("taps are test-only" — tests encode public behavior;
  the driver census must include hand-rolled drivers, `Resource.auto`,
  `Eta_stream`, and the public `step_plan`). E24 census targets (superseded
  by rescope — predict against the one-pager's gates, not its optimism).
  E24 omission-misreading direction (predicted "expects finite default";
  actual "unbounded" — the red-team's honest caveat beat my guess; F4
  registered). E25 `now_ms` "read correctly" (partial — units helped,
  wall-vs-monotonic still needs the mli sentence).
- Executor corps: E23 "no JS call sites" (false; orchestrator made the same
  wrong pre-flight claim — both now guarded by explicit JS-dir checks in
  every objective). E24 original census (missed with the rescope; scored
  honestly).
- Plan itself: E24's signatures were unwritable in OCaml (optional-last
  erasure) and its `retry_or_else` absorption was a misdiagnosis —
  two-error fallback is irreplaceable by `map_error` (V-DX-E24-003). The
  one-pager template now carries an erasure-check expectation.

**Not rubber-stamping (§4.5.3 argument).** Zero experiment kills, but: (1)
E24 was blocked pre-production with a reproducible probe and the contract
was amended — the process stopped work, it did not wave it through; (2) a
core plan objective (retry_or_else absorption) was killed by evidence
mid-flight, and another (Schedule.t slimming) hit its pre-registered hold
trigger — both recorded with evidence, both changed the merged shape; (3)
prediction misses are on record on all three sides (orchestrator, executor,
plan) and scored publicly; (4) two factual errors in executor reports were
caught in orchestrator verification (E23 JS claim; E24 none — it improved);
(5) review scores show real variance (old sides 3,3,1/3,3/3,4; new sides
not ceiling: fold-noise and cap-visibility caveats accepted as tradeoffs
F2/F4, not explained away).

**Plan adjustments adopted.** Oracle consultation is now a standing step
for contract amendments (E24 model: adversarial, fact-checked in code
before concession, consensus recorded). Erasure probes are mandatory for
any new optional-argument surface. Census concept-counting follows the
disclosed cluster definitions used in E23–E25 (map_error lives in the
transform cluster). Objectives require JS-track pre-checks in both lib and
test dirs.

**Backlog (registered).** E24b — schedule-hook ownership: policy vs.
driver (entry gate: full driver inventory incl. `step_with_hooks`; "retain
hooks permanently" is live). Retry cause-alignment decision (should
`retry` adopt composite-cause handling?). F1 `signal_jsoo` JS bit-rot
(pre-existing). F2 `fold ~ok:Fun.id` noise (watch). F3
`examples/catch_recovery.ml` filename. F4 `map_par` omission-vs-unbounded
misreading (mitigated by mli + docs + test; watch). F5 `Supervisor.scoped`
vs. `with_*` family vocabulary. Candidate (unregistered): `map_par`
default-8 measurement experiment on `bench/`.

**Spot-check list (§4.5.4 — all promotes rest partly on `[agent-sim]`
review evidence).** Priority order for a human eye: (1) E23 — highest-
traffic surface (`bind_error`/`fold`/`to_*`); (2) E24 — `map_par`
default-8 contract + retained `retry_or_else`; (3) E25 — `error_pp`
defect contract (raising printer now defects where a silent fallback
string existed).

**Protocol-compliance self-audit.** Predictions: dual-sealed on all three
experiments, commit-order verified (executor seals pre-code; orchestrator
seals pre-branch). Reviewer context: fresh oracle session per review;
packets randomized+blinded by orchestrator, keys sealed outside packet
dirs; advocating prose stripped (E25). Gates: orchestrator re-ran every
gate claimed by executors, plus mainline JS checks; master re-gated after
every merge. Kill criteria: pre-registered triggers honored (E24 slimming
hold). Stop conditions: none hit. Deviations: E23 step-batching of
protocol commits (accepted); E25 objective file gitignored instead of
plain-untracked (noted; harmless). No sealed prediction was ever edited.

**Phase B readiness.** Master green; dashboard refreshed; next: E1+E2+E3
batched per plan §4.8 preparation rules (single worktree, per-experiment
sections) unless the human directs otherwise; E2's `Effect.ignore` split
extends the CHANGELOG idiom-pass entry.

---

## V-DX-E1-001 — 2026-07-18 — research/dx-e1e2e3-hygiene — phase: predict (orchestrator-sealed, batch 1 of 3)

**Measured.** Construct cluster: `from_result`, `from_option` (labeled
`if_none:` — `sync_option` mirrors it), `flatten_result`, `sync`. The
two-combinator leaf pattern (`sync … |> flatten_result` and equivalents):
81 `flatten_result` call lines — the hottest boundary in the library.
`Eta_blocking.run_result` exists and docs prefer it (symmetry argument
holds). JS-track call sites: `test/cache_jsoo`, `test/js_jsoo` ×2,
`lib/http_js/eta_http_js.ml`.

**Census (predicted).** Construct cluster +2 vals (`sync_result`,
`sync_option`), +1 concept (thunk-with-boundary-type constructors, two
spellings — same accounting as `ignore*` in E23). Footguns: −1/+0
(hand-assembly of the leaf boundary is a forgettable two-step; becomes one
word).

**Teach-back (predicted).** "What does `sync_result` do to exceptions?" —
"surface as defects, like `sync`" answered 2/2 passes (oracle P-OCaml +
orchestrator). Kill gate (>1/3 passes expect exception-catching → rename to
`attempt_result`): predicted NOT fired.

**Review (predicted).** A/B of three leaf call sites (two-combinator vs
`sync_result`): new median ≥ 4; W1 solved without doc lookup in ≥ 2/3
persona passes (P-OCaml + orchestrator = 2/2 here).

**Persona mistakes.** P-OCaml: (1) expects `sync_result` to catch
exceptions (the kill-gate misreading — minority predicted); (2) tries
`sync_option` without `~if_none` first (label required, compiler-guided).
P-ZIO: (1) expects exception→typed conversion (ZIO `attempt` habit) —
docs must state exceptions stay defects; (2) expects `if_none` lazy (it is
an eager value — same as `from_option`).

## V-DX-E2-001 — 2026-07-18 — research/dx-e1e2e3-hygiene — phase: predict (orchestrator-sealed, batch 2 of 3)

**Measured.** `Effect.ignore` has ZERO production call sites — all 7 uses
are its own behavior tests in `effect_common_suites.ml` (success-discard,
fail-suppression, defect propagation, interrupt, finalizer). Migration =
splitting those tests + docs. Hold gate ("`ignore` was mostly
value-discard"): predicted NOT fired (tests cover both meanings; no
production bias either way).

**Census (predicted).** Handle cluster −1 val (`ignore` deleted;
`ignore_errors` generalized `(unit,..) -> ('a,..)` stays), concepts flat
(`ignore*` → `ignore_errors`); transform cluster +1 val (`discard` = the
`map (fun () -> ())` spelling). Footguns: −1/+0 (the most misleading name
in the surface per the one-pager). CHANGELOG idiom-pass entry extends.

**Teach-back (predicted).** "What does `ignore_errors` do to defects?" —
"nothing, they propagate" instant, 2/2. "What does `discard` do to typed
failures?" — "they propagate" (Stdlib `ignore` intuition transfers) 2/2.

**Red-team (predicted).** The swallowed-error bug now requires writing
`ignore_errors` explicitly — visible in a diff.

**Persona mistakes.** P-OCaml: (1) reaches for `Effect.ignore` out of
Stdlib habit, finds it deleted, reads CHANGELOG (predicted: smooth);
(2) momentarily expects `discard` to suppress (Stdlib `ignore` suppresses
exceptions... but Eta failures are values, not exceptions — predicted quick
self-correction). P-ZIO: (1) expects `ignore` to exist (ZIO `ignore`
discards value AND keeps errors — interesting: ZIO's `ignore` ≈ new
`discard` + error-keeping... predicted: looks it up, rates the split
honest).

## V-DX-E3-001 — 2026-07-18 — research/dx-e1e2e3-hygiene — phase: predict (orchestrator-sealed, batch 3 of 3)

**Measured.** `race : ('a,'err) t list -> ('a,'err) t` — homogeneous
success type. Heterogeneous races currently map-wrap both branches into a
common variant. `race_either` additive; mli must reference `race`'s
permit-acquisition caveat verbatim.

**Census (predicted).** Concurrency cluster +1 val / +1 concept
(heterogeneous race) — justified addition (T4 boilerplate around an
unambiguous boundary). Footguns: +0.

**Review (predicted).** A/B vs. the map-wrapped version on two snippets:
new median ≥ 4. Kill gate (`` `Left/`` `Right `` harder than named
variants): predicted NOT fired.

**Persona mistakes.** P-OCaml: (1) **`` `Left `` misread as the
error/failure case** (Haskell Either culture: Left = error) — the payload
types at the call site should correct it, predicted one hesitation, no
rating below 4; (2) expects the loser to keep running in background
(predicted: guesses cancellation correctly from `race` vocabulary).
P-ZIO: (1) expects `raceEither` semantics (first success, not first
settled — Eta's `race` fails fast on typed failure; predicted: one doc
lookup, correctly understood).

**Batch outcome (predicted).** All three promote. Gates green ≤3 fix
attempts per experiment; mainline compile checks on `test/cache_jsoo`,
`test/js_jsoo`, `lib/http_js`.

---

## V-DX-E1-002 — 2026-07-18 — research/dx-e1e2e3-hygiene — phase: results + decision (split verdict)

**Gates** (orchestrator re-run): native trio pass on master post-merge
(`b56af349`); mainline `test/cache_jsoo`/`test/js_jsoo`/`lib/http_js`
compile clean. `sync_result` parity tests green (Ok/Error/Die); mli doc
states the defect contract explicitly ("does not catch exceptions into the
typed channel").

**Review** `[agent-sim, spot-check]` — a three-pass saga. Round 1 (comments
present): two-combinator 5, `sync_result` 3 with a name-level caution
("plausibly misread"). The pre-registered kill gate fired provisionally
(1/1); fallback `attempt_result` retested and found decisively WORSE (2,
"attempt strongly suggests catching exceptions", high confidence — as the
orchestrator suspected from `Or_error` culture). Oracle consultation
(V-DX consultation 2) ruled the cohort incomplete and the endpoint
mis-measured: "count it as a failure only if the reviewer's own teach-back
was wrong". Completed cohort (name-only, signatures shown, no decoy):
teach-back wrong-routing **0/3**; `sync_result` ratings 3, 4, 5 → median
4 ✓; final pass used the signature's polymorphism as proof exceptions
cannot enter `'err` and preferred `sync_result` for the 80× case.

**Decision: PROMOTE `sync_result`; KILL `sync_option`.** The kill gate did
not fire on the completed cohort (0/3 wrong-routing). `sync_option` died on
*utility* evidence instead: `from_option` ×7 repo-wide, sync+option leaf
pattern ×0 — symmetry furniture (oracle: "consistency fetishism in the
opposite direction"). Removed surgically on master (`8c031422`); full E1
implementation remains on the branch as provenance.

**Prediction scoring (orchestrator).** Hits: kill gate "not fired" (right
outcome, wrong process — it provisionally fired first); `attempt_result`
worse (confirmed decisively); footguns −1/+0. Partial: census predicted
+2 vals/+1 concept → +1 val (sync_option's death halved the addition).
Executor: predictions consistent with outcome.

**Lesson for future gates:** review cohorts must be completed before gate
evaluation (≥3 comparable passes, uniform administration); "reviewer flags
possible ambiguity" ≠ "reviewer expects wrong semantics".

## V-DX-E2-002 — 2026-07-18 — research/dx-e1e2e3-hygiene — phase: results + decision

**Gates:** as E1 (shared merge). `Effect.ignore` fully deleted (0 public
refs); `discard` + generalized `ignore_errors` behavior tests green
(success discarded; typed failure/defect/interruption/finalizer
diagnostics propagate or are suppressed exactly per contract).

**Review** `[agent-sim, spot-check]`: old `ignore` rated **1** ("invites
exactly the bug where a developer intends only to discard a value but
silently suppresses failure"); the split rated **5** ("makes the failure
policy explicit and reviewable"). Strongest verdict in the programme so
far. Teach-back: `discard`/`ignore_errors` channel semantics read
correctly cold.

**Census/footguns:** handle −1 val, transform +1 val (verified);
footguns −1/+0. Hold gate (mostly value-discard) not fired — zero
production call sites existed; all 7 uses were behavior tests, split.

**Decision: PROMOTE.** Merged in `b56af349`; CHANGELOG idiom-pass entry
extended by the executor. Predictions (orchestrator + executor): all hit.

## V-DX-E3-002 — 2026-07-18 — research/dx-e1e2e3-hygiene — phase: results + decision (KILL)

**Review** `[agent-sim, spot-check]`: map-wrapped race with domain tags
(`` `Timeout``/`` `Done ``) rated **5** vs `race_either`'s
`` `Left``/`` `Right `` rated **4** — "explicit tags eliminate positional
Left/Right reasoning". The pre-registered kill gate ("reviewers find
`` `Left/`` `Right `` payloads harder to follow than named variants")
fired cleanly.

**Decision: KILL.** The map-wrapped recipe (domain-tagged variants)
remains the recommendation; `race_either` code stays on the branch as
provenance; the kill evidence bundle is committed at
`.scratch/research/dx/e3/` (+ shared review packet). Census stays flat —
the library is one val smaller than the one-pager assumed.

**Prediction scoring (orchestrator).** MISS: predicted the kill gate
would NOT fire and `` `Left `` would only cause "one hesitation, no
rating below 4". The reviewer read the tags correctly *and still*
preferred named variants — a cleaner loss than I imagined, and the
pre-registered gate did its job without sentiment. First full kill of the
programme; recorded as evidence that the gates have teeth.

---

## V-DX-E4-001 — 2026-07-18 — research/dx-e4e5-cause-corpus-type-errors — phase: predict (orchestrator-sealed)

Sealed before the branch existed. Batched with E5 per the programme's
batching rule (docs/tests-heavy, disjoint surfaces). Scored at -002.

**Current state (measured).** `Cause.pretty : ('err -> string) -> 'err t ->
string` exists (multi-line tree). No `pp_compact` anywhere. `Cause.Portable`
exists with `to_portable`; no `Cause_json` in `eta_otel`. Cause constructors
for the corpus: `fail`, `die`, `interrupt`, `interrupt_with_id`,
`sequential`, `concurrent`, `finalizer`, `suppressed`.

**Predicted shape.** `pp_compact` follows post-E25 `pp` culture:
`(Format.formatter -> 'err -> unit) -> Format.formatter -> 'err t -> unit`.
One line, no newlines ever (property test). Primary/finalizer distinction
survives via an explicit segment (e.g. `| suppressed: finalizer(...)`).

**Census (predicted).** Observability cluster +1 (`pp_compact`);
`eta_otel` +1 module (`Cause_json` over `Cause.Portable.t`); core stays
JSON-free. Footguns +0/−0 (additive).

**Review (predicted).** Error review board (oracle, P-OCaml): corpus
entries answer what/where/what-next without mli reading for the simple
cases; the hard cases (`Suppressed` × `Concurrent` × `Finalizer`, anonymous
vs identified interrupts) rate ≥ 3 with the primary/finalizer distinction
preserved. The pre-registered kill (compactness destroys primary/finalizer
distinction) does NOT fire — provided the suppressed segment stays
explicit. Predicted median ≥ 4 across corpus entries.

**Outcome (predicted).** Promote all three pieces (pp_compact, corpus,
encoder). Risk: the encoder's field naming gets one board comment, no
blocker.

---

## V-DX-E5-001 — 2026-07-18 — research/dx-e4e5-cause-corpus-type-errors — phase: predict (orchestrator-sealed)

Sealed before the branch existed. Scored at -002.

**Current state (measured).** Rank-2 surface: `Supervisor.child`
`('s, 'err, 'a)`, `Scope.t ('s, 'a, 'err)`, `body` record with `'s.`
quantification — skolem-escape errors exist to be captured. PPX: single
`Location.raise_errorf` funnel in `lib/ppx/ppx_eta.ml`, multiple call
sites. No cram-test convention in the repo (the experiment introduces one
or a script harness). No `docs/type-errors.md`.

**Predicted corpus.** 5–8 messages: Supervisor child escape (skolem),
`Scope.t` escape, 2–4 distinct PPX rejections, and at least one item from
the one-pager's list that turns out to be a RUNTIME error, not compile-time
(cross-domain primitive misuse — predicted; the page must say so
explicitly rather than force it into the compile corpus).

**Predicted page.** `docs/type-errors.md`: each entry = verbatim quoted
message (from the snapshot, so drift fails CI) + what-you-tried +
why-Eta-forbids + two canonical fixes. Snapshot drift gate: the cram/snapshot
test fails when compiler messages change.

**Review (predicted).** W5 rigged to trigger the escape: oracle solves
without the page slowly/wrongly, with the page explains the rank-2
rationale in its own words (one-pager's pass bar). Predicted pass; the
likely weak spot is OCaml's actual escape message being terse — the
page's value is highest exactly there.

**Census (predicted).** API +0 vals; docs +1 page; test infra +1 harness.
Footguns unchanged in count but the biggest one (rank-2 escape
unreadability) gets a documented mitigation — noted qualitatively, not as
a count change.

**Outcome (predicted).** Promote (one-pager: unconditional once the corpus
lands). By-product: a list of messages needing compiler-side work —
predicted 2–3 entries, mostly the skolem-escape texts.

---

## V-DX-E4-002 — 2026-07-19 — research/dx-e4e5-cause-corpus-type-errors — phase: results + decision

**Gates** (orchestrator re-run): native trio + mainline `test/cache_jsoo`
`test/js_jsoo` green in worktree; native trio green on master post-merge
(`f7395b0f`). 515 core tests incl. 12 new; 30 otel incl. 5 new.

**The kill gate fired — and the rework protocol worked.** Board review
`[agent-sim]` (oracle, P-OCaml): cases 1/3/4/5 PASS-WITH-COMMENT, **cases 2
& 6 FAIL** — `p | suppressed: f` never says the right side ran in a
*finalizer*. Executor's sealed prediction ("gate does not fire") and
red-team claim ("parens preserve the distinction") were both wrong the same
way: they covered structure, not role naming. One bounded rework round:
`p | suppressed: finalizer(f)` (existing vocabulary, self-delimiting;
composite sides drop redundant parens; dead paren row deleted). Re-review:
**continuity board** passed 2 (PASS) and 6 (PASS-WITH-COMMENT, density);
**cold reviewer** on the full revised corpus read both correctly from the
line alone. Kill gate answered "no" twice; no line judged worse than an
honest two-line render.

**Decision: PROMOTE all three pieces.** `pp_compact` (the gate's purpose
served — the shipped one-liner preserves the distinction, proven twice);
snapshot corpus (10 cases both forms + ~380-cause newline-freedom
property); `Eta_otel.Cause_json` (5 locked snapshots, core JSON-free).

**Prediction scoring (orchestrator).** Miss: "kill gate does not fire" —
it did; second under-prediction of a gate firing (E24 slimming was the
first; pattern recorded). Miss: predicted formatter-based shape — actual
string-based `('err -> string)`, consistent with neighbor `pretty`
(executor's call, defensible). Miss: census +1 → actual +2
(`interrupt_id_to_int` forced by the encoder; executor missed identically).
Hit: promote-all-three (post-rework); board engagement with the hard
cases; core stays JSON-free.

**Noted for later:** cold reviewer flagged compact `die(...)` as possibly
reading as process-termination to outsiders (tree says `defect:`) —
terminology watch, not omission.

---

## V-DX-E5-002 — 2026-07-19 — research/dx-e4e5-cause-corpus-type-errors — phase: results + decision

**Gates** (orchestrator re-run): native trio + `@type-errors-runtime`
(opt-in) green; **drift gate broken and healed by the orchestrator**
(injected line → exit 1 → restore → exit 0). 10 compile cases (3
supervisor rank-2 escapes, 7 PPX rejections), fenced to 5.2.0+ox.

**Archaeology findings (all with real captured output):**
1. Supervisor escapes (5 routes) are compile-time but the message is
   never "would escape its scope" — always `less general than "'s. …"`;
   the ref-leak message names neither the child nor the ref. Page entry 1
   exists exactly for this.
2. **Resource/Pool handle escape COMPILES — no fence exists** (empty
   stderr verified). Page entry 8 documents the trap.
3. **Cross-domain Channel: blocking pair HANGS silently (exit 124)**;
   `try_send` silently works; Queue contrast clean. Top by-product item:
   a same-domain runtime fence turning the hang into a named error.
4. Two PPX rejections (`requires at least one field`, `table type name is
   empty`) are unreachable from source — dead-code follow-up.
5. Cram evaluated and rejected experimentally (no `%{…}` expansion in cram
   scripts) — script harness instead.

**Review** `[agent-sim]` (two-phase protocol): phase 1 without page —
solved at 92% (fix matched canonical Fix 1); phase 2 with page — rated
9/10 ("solvable without the mli"); pass-bar teach-back: rank-2 rationale
explained in own words ("unforgeable type-level brand… typed
use-after-lifetime"). Honest caveat: the reviewer's type-system strength
made the without-page leg easy; the page's value is the with-page
explainability bar, which passed decisively.

**Decision: PROMOTE** (one-pager gate: unconditional once corpus lands).
`docs/type-errors.md`: 8 entries, verbatim-quotes mechanically verified,
linked from README footguns. By-product list (4 items) → backlog.

**Prediction scoring (orchestrator).** Hits: 5–8 messages (8); ≥1
category runtime-not-compile (cross-domain + the no-fence compile finding);
page pass bar; 2–3 compiler-side-work items (4); promote. Executor scored
its own message-shape miss ("would escape its scope" → `less general than
's.`) raw. Clean.

---

## V-DX-E6-001 — 2026-07-19 — research/dx-e6-scoped-with-helpers — phase: predict (orchestrator-sealed)

Sealed before the branch existed. Scored at V-DX-E6-002.

**Current surface (measured).** Lifecycle cluster in `effect.mli`: 6 vals —
`acquire_release`, `acquire_use_release`, `acquire_use_release_exit`,
`with_resource`, `with_resource_exit`, `with_scope`. No `Effect.Scoped`
module exists. 88 `with_resource` call-site lines repo-wide; true nested
`let@` ladders (2+ resources) are rare in-repo — this experiment serves
user code, not internal debt. JS track uses the lifecycle API in
`test/js_jsoo` ×2 — E6 only ADDS a module; no existing call sites migrate;
mainline compile check of `test/js_jsoo` covers the new code under OCaml 5.4.

**The shape.** `Effect.Scoped.with_2` / `with_3`: acquisition concurrent and
fail-fast (via the scope's own registration + `par`); a failed acquire
leaves the scope to release whatever was already registered; reverse-order
release inherited from `with_scope`. Arity > 3 = hand-rolled recipe. No
optionals anywhere (E24 erasure lesson — not applicable here).

**Teach-back (predicted).** "Second acquire fails — what happens?" answered
correctly from the mli alone: "the first resource's release still runs at
scope exit; releases run in reverse acquisition order."

**Review (predicted).** Blind A/B — 3-resource `let@` ladder vs
`Scoped.with_3`: ladder 3, with_3 4, with_3 preferred. THE risk point is
the pre-registered kill gate — `with_3`'s six labelled arguments
(`acquire1`/`release1`/…) reading worse than the ladder. Predicted NOT to
fire, but this is the experiment's live question. Screenshot test: nesting
depth 3 → 1.

**Persona mistakes (two each, predicted).**
- P-OCaml: (1) expects `with_2` to serialize acquisition (`Fun.protect`
  intuition is sequential); (2) expects a failed second acquire to leak the
  first resource (no scope model yet).
- P-ZIO: (1) looks for `Scope` as a passable value/capability, not a
  bracket; (2) reaches for the exit-aware release form out of
  `acquireRelease` habit.
- P-Maint: (1) asks whether release error rows `'r1`/`'r2` leak into the
  result (they don't — finalizer channel); (2) probes
  interrupt-during-acquire semantics per branch.

**Census (predicted).** Lifecycle cluster 6 → 8 vals; concepts +1
(parallel acquisition, two arities as one concept). Justification required
(R1 API-creep watch): replaces the proposed `and@` operator — syntax
machinery — with composition of decided semantics; the parking lot's
"and@ killed by E6" entry gains its evidence.

**Footguns (predicted).** −1/+0: the "nested `let@` ladder serializes
acquisitions that could be parallel" trap gets one obvious spelling.

**Outcome (predicted).** Promote helpers + recipe. Kill risk concentrated
in the `with_3` boilerplate rating; if it fires, recipe-only promotion.
Gates green within three fix attempts.

---

## V-DX-E6-002 — 2026-07-19 — research/dx-e6-scoped-with-helpers — phase: results + decision

**Outcome: helpers KILLED (pre-registered gate); recipe PROMOTED.**
Merged `--no-ff` (`123872bc`): ladder-first `docs/api-dx.md` section +
Expert-bridge recipe with worked example + 3 recipe regression tests + full
evidence bundle. Master gates green (orchestrator re-run); mainline
`test/js_jsoo` clean. No `lib/` changes survive — the branch's `feat` and
`revert` commits cancel out in the merge tree while preserving the full
experiment arc in branch history.

**Kill-gate evidence (cohort, ≥3 comparable passes per protocol).**
Blinded packet, fixed P-OCaml persona: ladder **5/5/4** (median 5) vs
`with_3` **3/3/3** (median 3); preference ladder 2/3. Consistent diagnosis
across all three reviewers: the name carries *cardinality, not execution
strategy* — concurrency invisible at the call site, release order dependent
on ordinal-label interpretation — while the ladder's lifecycle is
structurally visible. Flat-grouping scan advantage acknowledged by all
three; insufficient.

**Prediction scoring (orchestrator, V-DX-E6-001).** Hits: census 6→8 vals /
+1 concept (verified before excision), teach-back semantics (partial-
acquire release, reverse order — proven in tests), persona misreading
#1 (sequential reading of left-to-right labels — exactly what reviewers
did), promote-path gates green. **Miss: "kill gate predicted NOT to fire"**
— it fired, 3/3 passes. Executor: 65%-better prior miss; label-boilerplate
counterprediction hit. The sealed-prediction discipline caught both of us
anchoring on "less noise = better" and undervaluing structural visibility.

**What survives and why.** (a) Docs recipe — ladder default, Expert-bridge
for concurrent acquisition; progressive disclosure. (b) Three regression
tests proving partial-acquire release-once, reverse release order on
success + typed failure, ladder parity — the evidence outlives the API.
(c) The implementation finding: `par` children own local finalizer scopes,
so naive `map_par (acquire_release …)` drains releases early — the bridge
is *necessary*, now documented and tested. (d) `and@` stays killed on the
independent red-team (CPS composition serializes; syntax machinery would
not fix semantic invisibility either).

**Generalizable finding (the experiment's most valuable output):** helper
names must carry execution strategy, not just cardinality. Registered as a
naming-review criterion for all future experiments; a strategy-carrying
parallel-acquire name is backlog, not a rename rescue.

**Follow-ups carried:** F1–F4, E24b, retry cause-alignment, batch-2 backlog.
New: F5 strategy-named parallel-acquire helper (backlog, demand-gated).

**Phase B complete.** Synthesis: V-DX-PHASE-B.

---

## V-DX-PHASE-B — 2026-07-19 — phase synthesis: Phase B (hygiene)

**Evidence summary.** Six experiments, five outcomes on master, three kills:
- E1 (V-DX-E1-001/002): `sync_result` promoted — cohort 3/4/5, median 4,
  0/3 wrong exception-routings; mli states exceptions stay defects.
  `sync_option` KILLED — zero usage evidence (`from_option` ×7, sync+option
  leaf ×0); `attempt_result` fallback rejected (rated 2 — teaches
  exception-catching). Protocol upgrade born here: gates are not evaluated
  until the cohort (≥3 comparable passes) completes; E1's kill gate fired
  at 1/1 and was overturned at 3/3.
- E2 (V-DX-E2-002): `discard`/`ignore_errors` promoted — old `ignore`
  rated 1, split rated 5; CHANGELOG idiom-pass entry extended.
- E3 (V-DX-E3-002): `race_either` KILLED — domain-tagged variants rated 5
  vs positional `Left`/`Right` 4; map-wrapped recipe remains the
  recommendation; library stays one val smaller.
- E4 (V-DX-E4-002): `Cause.pp_compact` + snapshot corpus +
  `Eta_otel.Cause_json` promoted — board fired the kill gate on two
  composite cases (finalizer role label lost); one bounded rework
  (`finalizer(f)` notation); double re-review (continuity + cold) passed.
  Side findings: cram rejected experimentally for negative-compile tests
  (no `%{...}` expansion); `('err -> string)` chosen over formatter for
  `Cause.pretty` consistency.
- E5 (V-DX-E5-002): type-error translation page + negative compile corpus
  promoted — reviewer solved at 92% without the page, rated it 9/10,
  passed the rank-2 teach-back bar.
- E6 (V-DX-E6-002): helpers killed (cohort 3,3,3 vs 5,5,4), recipe
  promoted. Finding: names must carry execution strategy, not cardinality.

**Wrong predictions and lessons.**
- Orchestrator: E6 kill-gate-not-fired (miss — fired 3/3); E24 omission-
  misreading direction; E24 file-count. Pattern: I over-trust "less noise =
  better" and under-weight structural visibility of plain OCaml.
- Executors: E6 65%-better prior (miss); E24 original census targets
  (superseded). Executors consistently score their misses honestly —
  the dual-sealed format is doing its job.
- Plan itself: E24 optional-last signatures (unwritable); E24
  `retry_or_else` absorption (misdiagnosis); E6 helper value proposition
  (killed). The plan is holding up as a *process*, not as a *prophet* —
  exactly what it was designed to be.

**Rubber-stamp audit (§4.5.3).** Phase B does not need the zero-kill
defense: two clean kills (sync_option, race_either), one helper kill
(Scoped), one gate-fire-then-rework (pp_compact), one provisional gate
overturned by cohort completion (E1). Pre-registered gates overruled both
agent priors at least once (E6).

**Protocol-compliance self-audit.** Predictions: dual-sealed throughout,
commit-verified before code. Reviews: fresh-context oracle every time;
packets randomized/blinded by orchestrator; `[agent-sim]` + `SC` flags on
every review-backed decision. Journal: append-only; the one correction
(V-DX-E24-002a) done as a new entry. Gates: orchestrator re-runs native
trio on every merge; mainline JS checks per-experiment. Ops note: review
packets moved from /tmp to repo `.scratch` after sandbox variance (E6).
Batching (E1+E2+E3, E4+E5) worked cleanly with per-experiment sections and
mixed outcomes; no cross-contamination observed.

**Plan adjustments adopted.** (1) Cohort rule (E1). (2) Double re-review
after gate-firing reworks: continuity + cold (E4). (3) Review framing =
association-alignment probe, not "blindness" theater (post-E23 critique).
(4) Strategy-vs-cardinality as a standing review criterion (E6).

**Spot-check list (promote decisions resting on [agent-sim] evidence).**
E1 `sync_result`, E2 split, E4 `pp_compact`, E5 translation page, E6 recipe
— all `SC`. Recommended first reads for a human: the E5 translation page
and the E6 recipe docs — user-facing prose with the longest shelf life.

**Backlog triage (carried into Phase C+).** E24b hook-ownership; retry
cause-alignment; same-domain runtime fence (Channel/Pubsub/Pool silent hang
→ named error); dead PPX rejections ×2; resource/pool escape fence;
`Supervisor.Scope.start` first-contact error; `die` terminology watch;
F1 signal_jsoo; F2 `fold ~ok:Fun.id`; F3 `catch_recovery.ml`; F4 `map_par`
omission misreading; F5 strategy-named parallel-acquire helper (demand-
gated); candidate: `map_par` default-8 bench; strategy-named helper naming
criterion now applies to E7–E10 review packets.

**Phase C next:** E7 (error-pp deriver) → E8 (`[%eta.result]`) → E9
(Syntax.Parallel/Applicative) → E10 (hold default). E7/E8/E10 share
`ppx_eta.ml` — strictly sequential per plan. Master gates green at
`123872bc` + bookkeeping.

---

## V-DX-F1 — 2026-07-19 — follow-up closed: signal_jsoo mainline breakage (not an experiment)

Direct fix per programme decision (build health, no experiment ceremony).
Root causes found by probing mainline OCaml directly:

1. **OxCaml locally-quantified argument types** (`('a 'error. ty)` in
   argument position) are rejected by mainline OCaml — 9 sites across
   `eta_signal_timer`, `eta_signal_observer`, `eta_signal_graph` mlis and
   mls. Fixed with record-wrapped runners (the standard-OCaml rank-2
   idiom; probe-validated: record-field quantification compiles on both
   compilers). New public types: `node_runner`, `state_runner`,
   `update_runner`, `hook_runner`, `access_runner`, `delivery_runner`,
   `current_runner` + `Delivery_handle` internal runners.
2. **`'effect` is a reserved keyword** in mainline OCaml 5.x — unusable as
   a type variable or label (OxCaml accepts). Renamed to `'eff` / `~eff`
   (timer module).
3. **Stale jsoo expectations** (the suite hadn't compiled in ages):
   `monotonic_time` comparisons now via `Signal.Time.to_ms`; the
   runtime-mismatch assertion now accepts the deliberate
   `Suppressed{primary; finalizer}` composite — consistent with the native
   suite's composite-cause culture.

Verified: native gates (`build @install`, `runtest --force`,
`eta-oxcaml-test-shipped`) green; mainline `dune runtest
test/signal_jsoo` green (13 tests); `cache_jsoo`/`js_jsoo` still build.

**Ops knowledge (recorded for all future JS gates):** run mainline dune
with a dedicated build dir (`--build-dir=_build-mainline`, now gitignored)
to avoid the two compilers poisoning each other's `_build` — the
intermittent "RPC server not running" errors were track contamination.

Master `077f763e`.

---

## V-DX-F2 — 2026-07-19 — follow-up closed: `fold ~ok:Fun.id` noise — ACCEPTED (human decision)

Measured usage: 25 sites across examples, lib, tests — the pattern is hot,
which triggered the E23 revisit clause. Options: (a) accept as the Stdlib
idiom (`Result.fold ~ok:Fun.id` is exactly how OCaml writes pure
both-channel recovery today); (b) naming mini-experiment for a shorthand;
(c) restore `recover` (rejected on E23 review evidence — invites
exception-recovery readings).

**Decision (human, 2026-07-19): (a) accept.** `fold ~ok:Fun.id ~error:` is
the idiom; no shorthand experiment (E23b not scheduled). The north-star
sentence stands as written: `fold` on both channels.

---

## V-DX-E7-001 — 2026-07-18 — research/dx-e7-error-pp-deriver — phase: predict (orchestrator-sealed)

Sealed before the branch existed. Scored at V-DX-E7-002.

**Current shape (measured pre-change).** `lib/ppx/ppx_eta.ml`: 424 lines,
extension points only (`expand_sync_like` family) — **zero derivers**; E7
adds the first (`str_type_decl` infrastructure). `?error_pp` socket from
E25 in place: `with_error_pp`, `named ?error_pp`, `fn ?error_pp`. The
`"<typed failure>"` placeholder lives in `effect_core.ml`,
`runtime_observability.ml`, `runtime.ml`, `eta_jsoo.ml`. Error-type census
in `examples/`: ~14 declared error types across 35 polyvariant-using files;
**every visible payload is nullary or single `string`** — no int64/float/
multi-payload/inline-record cases. `docs/` similar.

**Census (predicted).** PPX forms cluster +1 (first deriver). Renderer
coverage in `examples/`+`docs/` error types: 0% → 100% — all derivable
within v1 scope (nullary + built-in payload types). Expansion snapshot
corpus: 6–8 shapes (nullary; each built-in payload; `[@eta.render]`
override; rejections for unsupported payload / nominal variant if out of
v1).

**Footguns (predicted).** −1/+0: the `"<typed failure>"` telemetry trap —
meaningful defaults become the path of least resistance.

**Review (predicted).** Error review board (fresh oracle, fixed persona)
rates before/after telemetry excerpts: before median ≤ 2 (`<typed failure>`
is information-free), after median ≥ 4 (domain-meaningful strings: tag +
payload). Expansion snippets rated as "code you would approve in a PR"
(plain match, T4). Kill gate ("payload long tail forces the deriver past
plain-match shape") predicted NOT to fire — examples/docs payloads fit v1.

**Persona mistakes (two each, predicted).**
- P-OCaml: (1) expects `[@@deriving eta_error]` to also derive `show`-style
  debugging output (scope confusion with ppx_deriving.show); (2) unsure
  whether the derived `pp_err` is wired automatically into spans or must be
  passed explicitly (answer: explicitly, via `?error_pp`/`with_error_pp` —
  T9 no ambient magic).
- P-Maint: (1) expects tuple/multi-arg constructors to render as tuples
  (v1: PPX-time error); (2) worries a raising `pp_err` poisons telemetry —
  E25 contract: becomes a defect, documented.

**Outcome (predicted).** Promote. Gates green within three fix attempts.
Risk point: PPX-time rejection message quality (T7 — messages are API);
the rejection snapshots will be reviewed on the error rubric.

---

## V-DX-E7-002 — 2026-07-19 — research/dx-e7-error-pp-deriver — phase: results + decision

**Gates** (orchestrator re-run): native trio pass in worktree AND on master
after the `--no-ff` merge (`df55d1df`). No JS-track package carries
generated code (verified); no mainline target required.

**Contract.** Deriver verified line-by-line: closed polymorphic variants;
built-ins `string`/`int`/`int64`/`float`/`bool` (`%s %d %Ld %g %b`);
`[@eta.render f]` identifier escape hatch incl. built-in override; hygienic
binders (`gen_symbol`, prevents capture through the attribute); tag rule
`Not_found` → `not_found`; every rejection via `Location.raise_errorf`
with what/where/what-next (nullary+attribute misuse, inherited rows,
multi-payload, unsupported payload, non-polyvariant). Expansion snapshots:
8 positive + 2 rejection — the generated binding is exactly the one-pager's
plain match (inside ppxlib's standard include wrapper; disclosed).

**Golden test** (real Eio runtime + `Tracer.in_memory`): same
`Effect.fail (`Db 7)` → `Error "<typed failure>"` without printer,
`Error "db:7"` with derived `pp_err`. Raising derived printer → `Cause.Die`
(E25 totality contract held, tested).

**Coverage.** 54 derived declarations across 49 example files; 23/23
named/fn sites wired with `~error_pp`; zero hand-written *telemetry*
printers remain (two `render_*` helpers verified as business-output
mapping, not telemetry — disclosed). Census: PPX forms +1. Footguns: −1/+0.

**Red-team 3/3:** placeholder attack rejected at PPX time (snapshot);
raising printer → defect; tag rename changes telemetry (honest, documented).

**Error board** `[agent-sim, spot-check]` (fresh oracle, fixed persona):
telemetry before **2** / after **4** ("database save failed with database
error code 7" — domain-meaningful); expansions **5,5** ("approve
verbatim"); cold comprehension 4/4 (explicit wiring, compile-time
rejection, raising→defect, rename→telemetry-incompatible). Closer:
hand-write when telemetry needs constructor-independent stable names,
cross-field formatting, or redaction — matches documented escape hatches.
Board observation → **F5**: a span-status string (`Error "db:7"`) does not
by itself distinguish typed failure from defect; that is the tracer's
status encoding, out of E7 scope — logged for the otel/E4-adjacent
follow-up list.

**Prediction scoring (V-DX-E7-001).** Hits: census +1; coverage 0%→100%;
footguns −1/+0; review before ≤2 (2) / after ≥4 (4); expansions
PR-approvable; kill gate unfired; promote. Miss: example declaration count
(predicted ~14, actual 54 across 49 files — same undercount direction as
E23; quick census keeps underestimating). Executor scored its observable
predictions 5/5 and declined to self-award review predictions — protocol
credit.

**Decision: PROMOTE.** Merged `--no-ff` (`df55d1df`); master gates green;
master + branch pushed; worktree removed; objective archived at
`.scratch/research/objectives/dx-e7-error-pp-deriver.md`.

---

## V-DX-E8-001 — 2026-07-19 — research/dx-e8-eta-result-sugar — phase: predict (orchestrator-sealed)

Sealed before the branch existed. Scored at V-DX-E8-002.

**Current shapes (measured pre-change).** `expand_sync_like ~ctxt ~kind expr`
(`lib/ppx/ppx_eta.ml:21`) already parameterizes the leaf kind;
`[%eta.sync "name" body]` expands to `Effect.fn __POS__ __FUNCTION__
(Effect.named name (Effect.sync (fun () -> body)))`. E8 = a `"result"` kind
+ `Extension.V3.declare "eta.result"` + generalized rejection message.
Usage: `[%eta.sync]` appears only in tests (0 example sites);
`Effect.sync_result` has ~56 call lines across examples/bench/lib — the
hand-written leaf is common, the sugar is not yet adopted. No JS-track ppx
usage anywhere.

**Scope note (evidence over symmetry).** The one-pager's conditional
`[%eta.option]` is OUT: E1 killed `sync_option` (zero usage evidence,
V-DX-E1-002), so the substrate does not exist. This is the
sugar-follows-frequency rule working, not an omission.

**Census (predicted).** PPX forms 1 → 2 (`[%eta.sync]`, `[%eta.result]`);
rejection paths +0 (same malformed-payload path, message generalized);
core vals +0. Footguns: +0/+0.

**Expansion contract (predicted exact).**
`Effect.fn __POS__ __FUNCTION__ (Effect.named name (Effect.sync_result
(fun () -> body)))` — the E23/E25-settled spellings. Snapshots: positive
expansion, malformed-payload rejection (non-string name; wrong arity —
message now names the actual form), behavioral parity with the
hand-written form through a real runtime + in-memory tracer (span name +
location present, `Error e` → typed, exception → `Die`).

**Adoption (predicted).** ~10–25 example sites convert (of ~56
`sync_result` lines — only leaves that want span naming; executor states
its conversion rule in the journal, predicted rule: leaves crossing an
IO/trust boundary get names, pure glue does not). `[%eta.sync]` adoption
side-effect: 0–3 sites. Operators per converted leaf boundary: 4 → 1.

**Review (predicted).** Screenshot test on the heaviest converted module:
median ≥ 4, no rating ≤ 2. Predicted reviewer remark: expansion is exactly
what you'd write by hand (T4 pass); one grumble that `[%eta.*]` is another
form to learn, accepted because the expansion is transparent. Kill gate
("the day the expansion needs explaining") does NOT fire.

**Red-team (predicted).** (a) Body that raises → defect preserved as `Die`
(E1 channel semantics survive the sugar); (b) sugar nested inside an
explicit `Effect.named` → nested spans, noisy-but-harmless, documented;
(c) T9 audit: every expansion identifier traces to the use site or
`__POS__`/`__FUNCTION__`.

**Gates (predicted).** Native trio green; `test/ppx_expansion/` snapshots;
conservative mainline compile check (`test/cache_jsoo`, `test/js_jsoo`)
despite zero JS ppx use. Outcome: promote. Risk points: per-site adoption
judgment calls; rejection-message generalization wording (T7 rubric).

---

## V-DX-E8-002 — 2026-07-19 — research/dx-e8-eta-result-sugar — phase: results + decision

**Gates** (orchestrator re-run): native trio pass in worktree AND on master
after the `--no-ff` merge; mainline `test/cache_jsoo` + `test/js_jsoo`
compile clean (executor claim confirmed).

**Contract.** `expand_sync_like` generalized with `~form`; `[%eta.result]`
registered with `kind:"sync_result"`. Expansion snapshot is the sealed
contract verbatim: `Effect.fn __POS__ __FUNCTION__ (Effect.named "db.find"
(Effect.sync_result (fun () -> body)))`. Rejections form-named
(`expected [%eta.result "name" body]`) with correct locations (T7).
Parity test: sugar ≡ hand-written for Ok / typed Error / raising body +
span name + outer-`fn` loc placement (matches existing `Effect.fn`
semantics — noted as deviation, correctly).

**Adoption.** Rule stated before conversion (IO/trust leaves with static
names, no special kwargs). 12 converted, 14 not — every non-conversion has
a concrete reason (`~error_pp`, dynamic names, lifecycle plumbing,
pedagogy). Note: converted sites *gain* spans they didn't have — deliberate
telemetry upgrade per the rule, not just sugar-for-boilerplate; recorded as
a semantic side effect. Operators per converted leaf boundary 4 → 1.

**Red-team 3/3:** raising body → `Cause.Die` with leaf + outer spans;
nested `Effect.named` → three spans, noisy-but-harmless, documented; T9
audit — every identifier traces to use site or `__POS__`/`__FUNCTION__`.

**Independent review** `[agent-sim, spot-check]` (oracle, fixed P-OCaml
persona, randomized pairs): leaf — sugar **4** vs hand **3** ("would accept
the long form as its exact hand-written expansion" — T4 pass; cost noted:
PPX hides generated metadata/defect behavior); heavy — sugar **4** vs hand
**4**, preference sugar; reviewer independently validated the adoption
rule (acquire/release correctly stay `Effect.sync` — converting would
"manufacture an inappropriate typed-failure shape merely for consistency").
Defect semantics read correctly cold in both forms. Median 4, no ≤2.

**Prediction scoring (V-DX-E8-001).** Hits: expansion exact; census 1→2
forms / +0 rejections / +0 vals; adoption in band (executor sealed 10,
actual 12); review median ≥4 no ≤2; "what you'd write by hand" remark;
kill gate unfired; red-team 3/3; gates green; promote. Miss: none scored
this round — first clean sweep; noted without celebration (single-sample
reviews remain the protocol's weak leg, flagged spot-check).

**Decision: PROMOTE.** Merged `--no-ff`; master gates green; master +
branch pushed; worktree removed; objective archived
(`.scratch/research/objectives/dx-e8-eta-result-sugar.md`).

**Follow-ups carried:** F1–F4, E24b, retry cause-alignment. New: none.
Queue: E9 (Syntax.Parallel/Applicative split) → E10 (hold default) →
Phase C synthesis.

---

## V-DX-E8-002a — 2026-07-19 — protocol note (branch discipline)

The E8 bookkeeping commit initially landed on `nema/ladybug-ro-classifier`:
the main checkout had been switched to that branch by concurrent
non-programme work between the merge and the bookkeeping commit. Repaired
by cherry-pick to master (`ef6e6a79`) and restoring their branch pointer to
`1bb62b8d` exactly; no non-programme work was touched. Rule going forward:
the orchestrator verifies `git branch --show-current` before every master
commit, and restores a foreign checked-out branch after master work rather
than assuming the checkout is on master. (Longer-term, concurrent
non-programme work belongs in its own worktree — raised with the human.)

---

## V-DX-E9-001 — 2026-07-19 — research/dx-e9-syntax-parallel-applicative — phase: predict (orchestrator-sealed)

Sealed before the branch existed. Scored at V-DX-E9-002. This is the first
experiment with a genuinely live kill gate; predictions say so honestly.

**Current shapes (measured pre-change).** `lib/eta/syntax.ml`: `( and* ) =
( and+ ) = Effect.par` — both operators are `par`, in the always-open
module alongside `let*`/`let+`/`let@`. `Syntax` is opened in ~40 files for
the let-forms, but `and*`/`and+` are actually USED in only 2 files
(`examples/background_lifecycle.ml`, `test/api_dx/api_dx_examples.ml`).
Migration is therefore tiny; the experiment's weight is in the review, not
the diff.

**The bet (from the one-pager).** `and*` = "fork fibers, cancel sibling on
failure" is invisible at the call site (T2). Splitting into
`Syntax.Parallel` (today's semantics) and `Syntax.Applicative` (strict
left-to-right, nothing forked) makes the `open` a declaration of intent.

**Baseline comprehension (predicted).** On today's implicit form
(`let open Syntax in let* x = a and* y = b in …`), asked "how many fibers
fork? what happens when `a` fails?": P-OCaml passes split — Lwt/Async
culture says `and*` is concurrent; Stdlib intuition says applicative =
sequential. Predicted 1 of 3 fully correct (both fibers AND sibling
cancellation), 2 of 3 missing at least the cancellation → baseline
33–50%, below the 80% kill gate. **Named kill risk:** the reviewer may know
ppx_let conventions from training data (Lwt's `and*` = `Lwt.both`) and
score baseline ≥ 2/3 — pushing toward the gate. Estimated kill
probability: ~30%.

**Explicit form (predicted).** `open Syntax.Parallel` + one doc paragraph:
3/3 correct on fibers and cancellation. `Syntax.Applicative`: 3/3 correct
on sequencing. Review target ≥ 80% explicit vs. baseline — predicted met
(100% vs ≤ 50%).

**Census (predicted).** Syntax operators: 5 vals → 7 (`and*`/`and+`
duplicated across two modules with different semantics) — growth,
justified per §3.1: sequential applicative gains a home it does not have;
concurrency becomes visible at the `open`. Modules +2. Footguns: −1/+0
(invisible-`and*` removed); new-trap candidate recorded: opening BOTH
modules shadows — mli must say "open exactly one".

**Mechanical (predicted).** Law tests: `Parallel` = par laws (pair order,
fail-fast cancels sibling — reuse existing par tests); `Applicative` =
sequencing laws (left settles before right starts — observable via
ordered side effects; zero fibers forked; fail-fast by sequencing).
Distinctness probe: the two `and*`s observably differ.

**Outcome (predicted).** Promote at ~70% confidence; kill at ~30%
(baseline too good). If killed, the recorded evidence is the answer to
"is `and*` obvious?" and the split idea goes to the parking lot.

---

## V-DX-E9-002-pre — 2026-07-19 — review scoring rule (pre-registered before any answers seen)

The one-pager's gates are evaluated strictly on two independent review runs
(separate fresh contexts; baseline run cannot contaminate explicit run).

**Runs.** Run 1 (baseline): `implicit.ml` (loads) + `implicit-race.ml`
(transfer), revealing comments stripped. Run 2 (explicit): `explicit-par.ml`
+ `explicit-app.ml`, same treatment. 6 factual questions per run + 2
unscored meta questions. Reviewers must guess even when uncertain and mark
confidence (certain/inferred/guess); confidence does not affect scoring.

**Scoring.** Per factual question: correct = 1; incorrect, "not determined",
unanswerable, or hedged-both-ways = 0. Correct answer key (committed
blind): old-shape/`Parallel` product — 2 fibers fork; left's typed failure
cancels the right; effect order NOT guaranteed. `Applicative` product —
0 fibers fork; order IS guaranteed; left failure means right never runs.

**Decision rule.** promote: explicit ≥ 5/6 AND (explicit − baseline) ≥ 2/6.
kill: baseline ≥ 5/6 (≈83%). Otherwise: hold, with the numbers published.
Granularity caveat recorded: 6 questions/run = 16.7-point steps.

---

## V-DX-E9-002 — 2026-07-19 — research/dx-e9-syntax-parallel-applicative — phase: results + decision (HOLD)

**Mechanical** (orchestrator re-run): native trio pass; mainline
`cache_jsoo`/`js_jsoo` pass. Implementation exactly per contract —
`Syntax` keeps `let*`/`let+`/`let@`; `Parallel` = `Effect.par`;
`Applicative` = sequential bind-map; top-level `and*`/`and+` removed, no
shim; mli within doc budget incl. "open exactly one". Law tests: Parallel
pair-order + fail-fast (cited par tests), Applicative strict L→R (ordered
log), right-waits-for-left (promise gate), fail-fast by sequencing,
interrupt-skips-right. Distinctness probe committed. Red-team: old-shape
order-sensitive writes race silently; Applicative version sequentially
correct. All green.

**Review** `[agent-sim, spot-check]` — two independent oracle runs (fresh
contexts, revealing comments stripped, uncontaminated), scored against
the pre-registered rule V-DX-E9-002-pre:

- Baseline (`implicit.ml`, `implicit-race.ml`): **2/6 (33%)** — "not
  determined, *certain*" on fibers, sibling fate, failure behavior;
  correct on order-not-guaranteed and order-matters.
- Explicit (`explicit-par.ml`, `explicit-app.ml`): **2/6 (33%)** — correct
  on second-open's role and order-matters; same "not determined" wall.
- Delta: 0. **Neither gate fires → HOLD**, numbers published (this entry).

**Readings.** (a) The footgun is real: both reviewers named it unprompted
("`and*` looks like ordinary product syntax but may conceal fiber
creation, sibling cancellation, effect ordering"; "the final `open`
silently determines `and*` semantics"). (b) The proposed names do not
carry the semantics: "`Parallel` communicates concurrency but not fork
count or cancellation"; "`Applicative` does not intuitively communicate
'ordered'". (c) The premise "open as declaration of intent" is contested:
baseline reviewer would accept it; explicit reviewer rejects it ("an
easily missed or reordered `open` should not silently determine
execution and failure semantics").

**Prediction scoring.** Orchestrator: baseline band 33–50% — hit (33%);
explicit 3/3 (100%) — **miss** (33%); promote ~70% — **miss** (hold).
Executor sealed baseline 55% — miss (33%). First experiment with a wrong
orchestrator outcome prediction; recorded without editing.

**Decision: HOLD.** Branch kept (pushed), worktree removed, objective
archived. Implementation is complete and green on the branch; it is NOT
merged because the comprehension case is unproven — the split's value was
its visibility, and the visibility measured zero.

**Follow-up registered: E9b hypothesis** (Phase C synthesis backlog):
rename hypothesis (`Concurrent`/`Sequential` vs `Parallel`/`Applicative`)
and the deeper alternative — semantics via *distinct operator names*
rather than module-switched `open`s (the explicit reviewer's critique).
Any E9b gets a fresh sealed prediction; no post-hoc retest of E9 shapes.

---

## V-DX-E9B-001 — 2026-07-19 — research/dx-e9b-honest-and-star — phase: predict (orchestrator-sealed)

Sealed before the branch existed. Scored at V-DX-E9B-002. Human design
decision (2026-07-19): option **B** — least astonishment — after the E9
hold showed module-switched `open`s carry no semantics (V-DX-E9-002).

**The contract.** `Syntax.( and* )` and `( and+ )` become the SEQUENTIAL
product (implementation = the E9 branch's `Applicative`: `Effect.bind
(fun a -> Effect.map (fun b -> (a, b)) right) left`). No submodules;
`Syntax` stays one module. Concurrency is spelled explicitly:
`Effect.par` (unchanged). The E9 split is abandoned as a design (branch
kept as provenance; its Applicative implementation + law tests are reused).

**Why this can promote on safety, not just comprehension.** Under the old
shape, misunderstanding `and*` wrote a *correctness* bug (silent race).
Under B, the order-sensitive transfer written with `and*` is correct by
construction; the only residual surprise is someone *wanting* concurrency
and getting sequencing — a latency surprise, observable and harmless, not
corruption. The red-team inverts: the invited bug is now unwriteable.

**Census (predicted).** Syntax operators 5 vals (unchanged — `and*`/`and+`
stay, semantics change); modules 1 (unchanged; E9's +2/+2 rejected).
Footguns: −1/+0 — invisible concurrency removed; the perf-surprise
("`and*` does not fork") documented in mli + `docs/api-dx.md`.

**Migration (predicted).** The 2 current `and*` files
(`examples/background_lifecycle.ml`, `test/api_dx/api_dx_examples.ml`):
sites with concurrent intent migrate to `Effect.par`; incidental sites
become sequential `and*`. Docs + law tests (ported from the E9 branch).
~10–15 files touched.

**Review (predicted).** Cold readers on the order-sensitive transfer
written with `and*`: zero correctness-risk misreadings (nobody's code
races); predicted ≥ 2/3 read sequencing correctly, rest "not determined"
(harmless under B). `Effect.par` read as forking: 3/3 (the name says it).
Pre-registered decision rule: **promote** iff (a) law tests green,
(b) red-team shows the transfer-with-`and*` is observably sequential and
a would-be-concurrent `and*` program is correct-but-serialized,
(c) review has ≤ 1/6 answers asserting `and*` forks/cancels (the old
dangerous misreading) and no other material misreading ≥ 2/6. **Kill/hold**
if a NEW dangerous misreading appears at ≥ 2/6 (e.g. readers believe
`Effect.par` is sequential).

**Outcome (predicted).** Promote at ~85% confidence. Residual risk:
Lwt-culture readers asserting `and*` = concurrent — safe under B (perf
misreading, not correctness), but counts in the review.

---

## V-DX-E9B-002 — 2026-07-19 — research/dx-e9b-honest-and-star — phase: results + decision

**Gates** (orchestrator re-run): worktree native trio pass; mainline
`cache_jsoo`/`js_jsoo` pass. Post-merge master gates: **red — but not
E9b's** (see incident below); isolated-worktree reproduction shows the
identical 8 failures, all ladybug, zero from E9b.

**Contract** (verified verbatim): `and*`/`and+` = sequential bind+map,
top-level in `Syntax`, no submodules, no shim; mli "strict left-to-right;
nothing is forked … for concurrency use {!Effect.par}"; `Effect.par`
untouched. Law tests Effect 56–59 green (strict L→R, right-waits,
fail-fast-by-sequencing, interrupt-skips-right). Migration: both `and*`
files moved concurrent intent to `Effect.par` (per-site justifications in
executor journal).

**Red-team 3/3** (output committed): (a) transfer-with-`and*` observably
sequential — correct by construction; (b) would-be-concurrent `and*`
program correct-but-serialized (latency only); (c) no concurrent `and*`
claims left in mli.

**Review** `[agent-sim, spot-check]` (oracle, fixed P-OCaml persona,
comments stripped): assertions that `and*` forks/cancels: **0/6**
(rule allows ≤ 1). `Effect.par` read correctly as "requests parallel
execution". No other material misreading. Reviewer's bonus finding, now
the strongest articulation of the design: "ordinary left-to-right
intuition is misleading because `Effect.t` values are lazy blueprints" —
a rigorous reader won't commit to ANY combinator reading; under B,
not-knowing is *safe* (latency, never corruption).

**Decision rule (sealed, V-DX-E9B-001): all three clauses pass.**
**Decision: PROMOTE.**

**Prediction scoring.** Hits: contract; census 5 vals/1 module; footguns
−1/+0; red-team both outcomes; review zero dangerous misreadings;
promote. Misses: (1) predicted ≥ 2/3 would read sequencing correctly —
actual 0/3 correct, all "not determined" (rigorous non-commitment; safe
under B, but a miss on my comprehension guess); (2) migration split —
predicted some incidental sites stay sequential-`and*`; actual all 2
files' sites wanted concurrency and moved to `Effect.par`.

**Incident (recorded fully).** Post-merge master gates red: 8 ladybug
failures, `missing symbol lbug_prepared_statement_is_read_only` in the
mock (`test/ladybug_leak/ladybug_mock_lib.c`) and on the fallback-soname
path. Root cause: unpushed merge `9e2e3be1` (2026-07-19 17:01,
`nema/ladybug-ro-classifier` → master, created outside the DX programme)
brought the read-only classifier's OCaml binding to master without the
mock symbol. Evidence: `git reflog master`; isolated worktree at the E9b
merge reproduces the identical 8 failures; `git show` proves master
pre-ladybug had 0 occurrences. E9b's merge (`006c2572`) is clean ort and
contributes zero failures. **Push of master withheld** (would publish a
red suite + the programme-external ladybug work). Options reported to the
human: (a) ladybug workstream adds the mock symbol; (b) orchestrator adds
a conservative mock symbol with the human's blessing; (c) revert
`9e2e3be1` to keep master green, ladybug continues on its branch. Rule
proposed: master stays green — whoever merges to master runs the full
gate first.

---

## V-DX-E9B-002b — 2026-07-19 — incident resolved

The ladybug workstream fixed the ABI gap on master (`7a16e6fb`
"fix(ladybug): keep test drivers ABI-complete" — mock now exports
`lbug_prepared_statement_is_read_only`). Full master gates re-run in an
isolated worktree at `7a16e6fb`: **green, zero failures**. Master pushed
(`4d8441ce..7a16e6fb`): includes the ladybug merge, the E9b merge
(`006c2572`), and E9b bookkeeping. Isolated worktree removed. Rule
recorded: master stays green — whoever merges to master runs the full
gate first.

---

## V-DX-E10-001 — 2026-07-19 — research/dx-e10-function-sugar — phase: predict (orchestrator-sealed)

Sealed before the branch existed. E10 is the programme's hold-default
experiment: the deliverable is evidence for the hold/promote decision, not
a promotion push.

**Frequency evidence (measured pre-change).** `Effect.fn __POS__` = **5
sites repo-wide** (3 in tests). `[%eta.sync]`/`[%eta.result]` = 66 uses in
`examples/`. The definition-site boilerplate E10 targets has already been
absorbed by E8's leaf sugar. T4's "demonstrated frequency" bar: not met by
current usage. This is the load-bearing fact of the whole experiment.

**Expansion (predicted).** Both spellings implementable with the E7/E8
machinery: `let%eta f x = body` → `let f x = Effect.fn __POS__
__FUNCTION__ body`; `[@@eta.trace]` the same as a structure-item attribute.
Labeled/optional/`let rec` shapes work; wrapper-inside recursion semantics
defined and documented (each recursive call re-enters `fn` — spans per
call). Expansion stays one line; `.mli` unchanged (representation-level).

**Error locations (predicted).** Mistyped body: error points into the body
(locations preserved), wrapper name visible in the trace; board rating 3–4.
Kill gate (≤3 and unimprovable) does NOT fire.

**Review cohort (predicted).** A/B of a real converted module:
hand-written ~4, sugar ~3–4. The plan's sealed prediction stands: "authors
like it, reviewers neutral-to-negative" — the "sugar reads like behaviour"
concern appears in comments. On the hold-gate question ("after E7/E8, do
you still want this?"), reviewers told the frequency data (5 sites) do
NOT ask for it.

**Outcome (predicted).** HOLD — the pre-registered default. Promote
condition ("reviewers still ask") unmet; kill gate unfired. Census: PPX
forms stay 3 (`[%eta.sync]`, `[%eta.result]`, `[@@deriving eta_error]`).
Footguns ±0. Value of the experiment: the hold becomes evidence-backed
(expansion corpus + error-location corpus + review), not a hunch — and the
corpus is the ready-made record if definition-site `fn` usage ever grows.

---

## V-DX-AMEND-2 — 2026-07-19 — frequency evidence is user-first (protocol amendment, supersedes frequency framing everywhere)

Human correction, adopted as standing protocol: Eta is a library; the
consumers that matter are *applications using Eta*, not Eta's own internal
cross-package or test consumers. Consequences for all past and future
experiments:

1. **Frequency evidence counts user-shaped code with full weight:**
   `examples/`, docs-taught patterns, and downstream consumers. A pattern
   the docs teach is user-facing demand even at zero internal usage.
2. **Internal usage (lib cross-package, tests) is weak evidence** — it
   measures our own shortcuts (leaf sugar), not user need.
3. Applied to E10 immediately: the "5 sites, all tests" census is weak
   evidence; the user-facing facts are (a) README/api-dx teach
   `Effect.fn __POS__ __FUNCTION__` as the way to get function-name spans,
   (b) the one example using it needs `~error_pp`/`~kind` — a form the
   prototyped sugar does NOT cover (plain `fn` only). The review cohort's
   frequency question is reframed user-first accordingly.

---

## V-DX-E10-002 — 2026-07-19 — research/dx-e10-function-sugar — phase: results + decision

**Gates** (orchestrator re-run): native trio pass. PPX is compile-time; no
JS-track impact. Expansion corpus (`j_`–`o_`) matches the sealed one-liner
shape; `wrap_result_position` verified in `ppx_eta.ml` (params/constraints/
newtype/coerce preserved; wrapper inside `let rec` — per-call spans proven,
`countdown 3` → 4 spans). Error-location corpus 4–5 (kill gate ≤3:
**does not fire**). `.mli` invariance proven for all three forms.

**Review cohort** `[agent-sim, spot-check]` (3 fresh-context oracle passes,
P-OCaml persona, user-first frequency framing per V-DX-AMEND-2):

| Pass | handwritten | `let%eta` | `[@@eta.trace]` | asks for sugar? |
|---|---|---|---|---|
| 1 | 4,4 | 3,3 | 5,5 | yes (conditional) |
| 2 | 4,4 | 3,3 | 5,5 | no |
| 3 | 5,5 | 3,3 | 5,5 | yes |

- **`let%eta` KILLED** (unanimous): does not name the tracing intent; reads
  as a general effect transformation; no pass would accept it verbatim.
- **`[@@eta.trace]`** (unanimous clarity): attribute = metadata on an
  ordinary definition; verbatim-PR acceptable; named ship-candidate by all
  three passes including the hold voter.
- Frequency split: passes 1+3 predict the plain form is the common case
  (custom args exceptional → hand form is a *useful* distinction); pass 2
  predicts boundary functions disproportionately need `~error_pp`/`~kind`
  (plain-only sugar = two spellings for one concept). Untestable without
  external consumers.

**Decision: HOLD.** The promote condition ("reviewers still ask") is not
decisively met (1 unconditional yes / 1 conditional / 1 no), and T4's
demonstrated frequency cannot be established with zero external consumers.
The hold is sharp, not vague: (a) `let%eta` killed with evidence;
(b) `[@@eta.trace]` pre-selected; implementation, snapshots, and corpus
complete on the kept branch — promotion is a merge when the trigger fires;
(c) **promote trigger defined**: application code showing the plain wrapper
pervasive at function boundaries AND `~error_pp`/`~kind` rare, or evidence
that developers omit function spans due to boilerplate.

**Prediction scoring (orchestrator, V-DX-E10-001).** Hits: expansion
shapes; error locations 3–4 predicted / 4–5 actual (kill unfired); HOLD
outcome; census flat. Misses: "reviewers do not ask" (2/3 asked, one
conditionally); "sugar ~3–4" (attr form rated 5 uniformly — I priced the
spelling risk into the wrong spelling). Executor predictions: all hit.

**Follow-ups:** none new. The branch remains the ready record.

---

## V-DX-E1-003 — 2026-07-20 — decision: `sync_option` promoted by human decision authority

Human override of the E1 `sync_option` kill (V-DX-E1-002), exercised under
the programme's supreme rule (human instructions outrank the plan).
Rationale: "who cares if Eta is using it?" — the kill rested on zero
*internal* usage, which V-DX-AMEND-2 (adopted after the kill) classifies as
weak evidence. User-first, the construct family is a symmetric 2×2:
`from_result`/`from_option` for computed values, `sync_result`/`sync_option`
for thunks — one breath to teach, and the name's comprehension was never
challenged (the kill was utility-only). The E1 decision is not re-scored:
decisions are revisited when the evidence rules change; the amendment
changed the rules. Implementation delegated to a spawned agent; gates and
merge by orchestrator. Census: construct cluster +1, justified as family
completion.

---

## V-DX-E1-004 — 2026-07-20 — outcome: `sync_option` landed

Implementation by a delegated high-tier agent (orchestrator-reviewed):
`sync_option ~if_none f = bind (from_option ~if_none) (sync f)` — the
honest composition; mli doc states the channels in the family voice
(`None` → typed `if_none`; exceptions → `Cause.Die`, not `bind_error`-able);
parity test `sync_option parity` (Some/None/exception); docs updated across
README, api-dx (4 spots), CHANGELOG (Unreleased/Added), dx.md (E1 entry now
tells the honest kill→promote history). Merged `--no-ff` (`98aeebb6`),
master gates green, pushed. Census: construct cluster 8 → 9 vals —
justified as completion of the public 2×2 (`from_result`/`from_option` ×
`sync_result`/`sync_option`), per the human decision.

---

## V-DX-PHASE-C — 2026-07-20 — phase synthesis: Phase C (syntax & PPX)

**Evidence summary.** Five experiments, three promotes, two holds, one kill:
- E7 (V-DX-E7-001/002): `[@@deriving eta_error]` **promoted** (`df55d1df`) —
  plain-match `pp_err` for closed polymorphic variants; built-in payloads;
  `[@eta.render f]` escape; every rejection PPX-time with what/where/
  what-next. Golden test: `<typed failure>` → `db:7` through real Eio +
  in-memory tracer. 54 derivations across 49 example files; 23/23 named/fn
  sites wired; zero hand-written telemetry printers. Board: telemetry
  2 → 4; expansions 5,5 "approve verbatim". T6 satisfied in examples.
- E8 (V-DX-E8-001/002): `[%eta.result "name" body]` **promoted** — expansion
  is the sealed contract verbatim; adoption rule stated before conversion
  (IO/trust leaves with static names); 12 converted / 14 stayed with
  per-site reasons; operators per leaf boundary 4 → 1. Review: sugar 4 vs
  hand 3; reviewer independently validated the adoption rule. First
  all-hit prediction round. `[%eta.option]` excluded — the substrate was
  killed at the time; sugar follows frequency, not symmetry.
- E9 (V-DX-E9-001/002-pre/002): `Syntax.Parallel`/`Applicative` split
  **held** — baseline 2/6, explicit 2/6, delta 0; neither pre-registered
  gate fired. Readings: the footgun is real (named unprompted by both
  reviewers); the proposed module names carry no semantics; the premise
  "open as declaration of intent" contested. Branch kept as provenance;
  the design itself superseded by E9b.
- E9b (V-DX-E9B-001/002/002b): `and*`/`and+` **sequential everywhere**,
  concurrency spelled `Effect.par` — **promoted** (`006c2572`) by human
  design decision (option B, least astonishment). Safety inversion: under
  the old shape, misreading `and*` wrote a correctness bug (silent race);
  under B, the worst case is a latency surprise. Review: 0/6 dangerous
  misreadings; red-team 3/3 (race unwriteable). Strongest articulation
  from the reviewer: a rigorous reader won't commit to ANY combinator
  reading of lazy blueprints — under B, not-knowing is *safe*.
- E10 (V-DX-E10-001/002, V-DX-AMEND-2): function sugar **held** — cohort
  3 passes: `let%eta` **killed** (3×6 unanimous — names the library, not
  the intent); `[@@eta.trace]` validated (5×6) and pre-selected with a
  defined promote trigger. Kill gate unfired (error locations 4–5).
  Amendment born here: frequency evidence is user-first.

**What Phase C teaches (the durable laws).**
1. **Sugar that mirrors decided semantics earns its place; sugar that
   renames without semantics dies.** E7/E8/`[@@eta.trace]` (5s) expand to
   already-decided shapes; E9's split (delta 0) and `let%eta` (3s) renamed
   without adding meaning.
2. **Names must carry intent, not provenance.** `eta.trace` says *trace*;
   `%eta` says *Eta*. `Applicative`/`Parallel` said neither *ordered* nor
   *fork-count+cancel*. (Extends the E6 law: names carry execution
   strategy.)
3. **Safety beats comprehension for operator semantics.** E9b promotes on
   "the misreading is now harmless", not on "everyone reads it right" —
   with lazy blueprints, rigorous readers won't commit to *any* reading
   (0/3 correct, all "not determined", all safe).
4. **Gate-bearing reviews get pre-registered scoring rules**
   (V-DX-E9-002-pre) — sealed before any answers seen. Strongest
   anti-post-hoc protocol in the programme; now standard.

**Wrong predictions and lessons.**
- Orchestrator: E9 explicit-form 3/3 → actual 2/6 (miss); E9 promote ~70%
  → hold (miss); E9b ≥2/3 read sequencing → actual 0/3 correct-but-safe
  (miss); E10 "reviewers won't ask" → 2/3 asked (miss); E10 attr ~3–4 →
  actual 5×6 (miss); E7 declarations ~14 → 54 (miss, same undercount
  direction as E23 — quick censuses keep underestimating). Pattern of the
  phase: I over-estimate what names can prove about *semantics* (the
  "not determined" wall) and misprice spelling risk between forms.
  Hits: E7 census/coverage/ratings; E8 clean sweep; E9 baseline band;
  E9b contract/red-team/promote; E10 outcome + kill gate.
- Executors: E9 baseline 55% → 33% (miss); otherwise accurate and
  honestly scored (E7's executor declined to self-award review
  predictions — protocol credit).
- The plan: E9's premise measured zero visibility; E10's brief produced
  one killable and one validatable spelling — process over prophet, again.

**Rubber-stamp audit (§4.5.3).** Not needed-but-shown anyway: 1 kill
(`let%eta`), 2 holds (E9, E10), and E9b's promote required a fresh human
design decision plus a three-clause sealed decision rule. Gates fired and
were honored (E10 kill gate evaluated, unfired on evidence).

**Protocol-compliance self-audit.** Predictions dual-sealed for all five,
commit-verified; E9 added the sealed scoring rule. Reviews: fresh-context
oracle passes throughout; E9 used two independent uncontaminated runs;
E10 a 3-pass cohort. Incidents, all recorded and fixed: (1) E8 bookkeeping
landed on a foreign branch (checkout switched by concurrent non-programme
work) — repaired by cherry-pick (`ef6e6a79`); rule: verify
`git branch --show-current` before every master commit (V-DX-E8-002a).
(2) Post-E9b master red — root-caused to a programme-external ladybug
merge (`9e2e3be1`), E9b proven clean by isolated reproduction; fixed by
the ladybug workstream (`7a16e6fb`); rule: **master stays green — whoever
merges runs the full gate first** (V-DX-E9B-002b). (3) Orchestrator
bookkeeping miss: E10 dashboard row left uncommitted, caught by an agent
baseline commit; fixed (`ca650db7`). PPX-file sharing honored: E7→E8→E10
strictly sequential.

**Plan adjustments adopted.** (1) Sealed review scoring rules for
gate-bearing reviews. (2) V-DX-AMEND-2 user-first frequency. (3) Branch
discipline rule. (4) Master-stays-green rule. (5) Human design decisions
get their own sealed-prediction experiments (E9b pattern), not post-hoc
retests of held shapes.

**Spot-check list (promote decisions resting on [agent-sim] evidence).**
E7 (telemetry strings are a stable-dashboards contract), E8 (adoption
rule's 12 site judgments), E9b (`and*`'s meaning changed everywhere —
partially de-risked: the design was human-chosen). Recommended first
reads: E9b's mli paragraph (`and*` strict left-to-right + `Effect.par`),
then E7's generated `pp_err` next to one hand-written renderer.

**Backlog triage (carried into Phase D).** E24b hook-ownership (after
E19/E20 context); retry cause-alignment; same-domain runtime fence;
dead PPX rejections ×2; resource/pool escape fence;
`Supervisor.Scope.start` first-contact error; `die` terminology watch;
F3 `catch_recovery.ml`; F4 `map_par` omission misreading; F5 span-status
typed-vs-defect encoding (otel/E4-adjacent); `map_par` default-8 bench;
`[@@eta.trace]` promote trigger (watch for real-app frequency);
`[%eta.option]` stays excluded — the substrate exists again (V-DX-E1-003)
but the frequency rule still gates the sugar; E9 split → parking lot
(superseded by E9b; branch kept as provenance).

**Phase D next:** E26 (`fresh`, warm-up) → E19 (scoped capability
override — flagship; E24b context follows it) → E20 (intercept) → E12
(audit/describe) → E11 (Eta_test.run) → E13 (async) → E14 (Promise,
hold-gated). Master green at `5943585a`.
