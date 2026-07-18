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
