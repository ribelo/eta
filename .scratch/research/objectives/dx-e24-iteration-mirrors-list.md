# Objective: DX-E24 — Iteration mirrors `List`: `map_par`, one `retry`, slimmer `Schedule.t`

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e24`
- Branch: `research/dx-e24-iteration-mirrors-list` (already checked out here; do not create others)
- Phase: A (idiom pass) · Effort M · Risk low–med (`Schedule.t` type change ripples)
- Evidence IDs: `V-DX-E24-*` (orchestrator log); your journal is the branch record

## Executor profile

Type-driven API surgery plus a large migration: `Schedule.t` loses a type
parameter across every public type and combinator; `retry`/`repeat` are
reshaped (labeled + optional args, observers replace schedule taps); two
parallel-iteration functions merge into one with an optional bound; ~265
call-site lines migrate. The difficulty is OCaml type-level care (the
3-param → 2-param ripple through `t`/`driver`/`step`) and behavior-parity
test design — you must *prove* the new shapes behave identically, not
assert it. Docs-first discipline, no design invention: signatures below are
the contract.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Iteration
should mirror `List`: `map` collects, `~f` labels the function, optional
arguments replace duplicate function families. The north star from E23
stands: *`Effect` is `Result` with concurrency and spans.*

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file. Nix-only gates, no
   shims, delete old paths, break loudly, conventional commits.
2. `lib/eta/effect.mli` — the iterate cluster (`for_each_par`,
   `for_each_par_bounded`, `retry`, `retry_or_else`, `repeat`) and its
   implementation.
3. `lib/eta/schedule.mli` + `schedule.ml` — the `('input, 'output, 'hook) t`
   type, `no_hook`, `tap_input`/`tap_output`, `driver`, `step`.
4. `test/core_common/effect_retry_repeat_common_suites.ml` — current tap
   usage (16 lines; taps exist only in tests) and retry/repeat behavior
   tests you will migrate and extend.
5. `.scratch/research/dx/e23/journal.md` and `report.md` — the previous
   experiment's executor record; your format should match or beat it.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
The design is decided (signatures below are the contract); skip
hypothesis-space theatre. Your proof obligations: **behavior parity**
(result order, fail-fast, bound enforcement, `or_else`'s `None`/`Some`,
observer failure rules) and **migration completeness**. Parity is a test
suite, not a claim.

Working artifacts in `.scratch/research/dx/e24/` **on this branch**
(commit them): `journal.md`, `report.md`, `redteam/`, `review/`.

## The experiment (one-pager, from DX-PRD-0001 §E24)

**Proposal.**

```ocaml
val map_par :
  'a list -> f:('a -> ('b, 'err) t) -> ?max_concurrent:int -> ('b list, 'err) t
  (* absorbs for_each_par and for_each_par_bounded; Invalid_argument if
     max_concurrent <= 0 *)

val retry :
  ('a, 'err) t ->
  schedule:('err, 'out) Schedule.t ->
  while_:('err -> bool) ->
  ?on_retry:('err -> 'out option -> (unit, 'err) t) ->
  ?or_else:('err -> 'out option -> ('a, 'err) t) ->
  ('a, 'err) t
  (* absorbs retry_or_else; or_else receives None when the predicate rejects
     the first failure before any schedule step — current semantics preserved *)

val repeat :
  ('a, 'err) t -> schedule:('a, 'out) Schedule.t ->
  ?on_repeat:('a -> 'out option -> (unit, 'err) t) -> ('out, 'err) t
```

`Schedule.t` drops its third parameter (the effectful-tap channel) and
becomes `('in, 'out) Schedule.t`; taps leave the schedule type and become
observer arguments at the call sites. Deletions: `for_each_par`,
`for_each_par_bounded`, `retry_or_else`, the old `retry`/`repeat` shapes.

**Semantics & edges.** Fail-fast, input-order results, cancellation: all
unchanged. The `~f` label follows `List.map ~f` (T11). Observer failures
follow the current tap-failure rules (they fail normally through the typed
channel); the mli states it. Callers of schedule taps migrate to observers —
mechanical, compiler-guided.

**Gates from the one-pager.** Promote on parity green + review pass. Hold
the `Schedule.t` slimming specifically if the tap migration exposes uses
that observers cannot express (record; the renames still promote).

## Protocol (predictions commit FIRST and separately; then step commits)

1. **Seal your predictions** in `.scratch/research/dx/e24/journal.md`
   (`Predictions (sealed)`): expected teach-back answers
   (`?max_concurrent`, `~while_`, result order, sibling fate), expected
   census/footgun deltas, two likeliest reviewer misreadings. Commit before
   any code change (`docs(dx-e24): seal predictions`). Never edit afterward.
2. **Docs-first.** Rewrite the `.mli` contracts for `map_par`, `retry`,
   `repeat`, and the slimmed `Schedule.t` before implementation. The
   `Schedule.t` docs should lose their hardest paragraph (the hook channel)
   — if they don't, note it. Observer-failure rules must be stated where
   `?on_retry`/`?on_repeat` are documented.
3. **Implement the smallest change.** Slim the type, reshape the three
   combinators, delete the old names, migrate every call site the gates
   build, including docs code blocks and the 3 jsoo test files.
4. **Gates** (from the worktree, exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   ```
   **JS track (known call sites — E23 lesson):** `test/cache_jsoo`,
   `test/js_jsoo`, `test/signal_jsoo` contain migrated names. Verify:
   ```sh
   nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo
   ```
   `test/signal_jsoo` is pre-broken on master (F1, see
   `.scratch/research/dx/e23/` journal) — confirm its failure output is
   unchanged from master's; do NOT fix it; record both outputs in your
   journal.
   Fix-forward up to three attempts per failure class, then BLOCKED.
5. **Mechanical extras.**
   - **Parity suite** in `test/core_common/effect_retry_repeat_common_suites.ml`
     (or its neighbors): `map_par` preserves input order under
     interleavings; fail-fast cancels siblings; `?max_concurrent` enforces
     the bound (peak-concurrency probe); `Invalid_argument` on
     `max_concurrent <= 0`; `retry`'s `?or_else` receives `None` on
     first-rejection, `Some out` after steps, `Some` of terminal output at
     exhaustion; observer failure fails the typed channel; tap→observer
     migrated tests prove the same observations happen in the same order.
   - Census table: iterate cluster before/after (orchestrator pre-count:
     5 vals → 3; concepts 5 → 2; Schedule params 3 → 2; `tap_input`/
     `tap_output` deleted). Verify independently.
   - Footgun delta: expect −2/+0.
   - Update `docs/api-dx.md` iteration/schedule guidance to the new
     spellings — explicit checklist item.
6. **Red-team pass.** Two probes, committed under
   `.scratch/research/dx/e24/redteam/` with verdicts:
   (a) `map_par ~max_concurrent:0` — must fail loudly (`Invalid_argument`),
   not silently unbounded; (b) an `?on_retry` observer that tries to
   *stop* the retry loop — show observers cannot alter control flow, only
   observe (and that observer failure fails the channel).
7. **Review packet** in `.scratch/research/dx/e24/review/`, labeled (the
   orchestrator blinds it): two A/B pairs, 10–30 lines each —
   (a) `par-old.ml`/`par-new.ml`: a bounded-parallel fetch of a list of
   ids, old vs. new shape; (b) `retry-old.ml`/`retry-new.ml`: retry with a
   schedule, a predicate, and a fallback, old vs. new shape. Plus
   `MANIFEST.md` and `QUESTIONS.md` (guess-the-semantics prompts:
   `?max_concurrent`, `~while_`, result order, what `?or_else`'s argument
   is).
8. **Report** in `.scratch/research/dx/e24/report.md`: gates summary,
   parity-suite evidence, census/footgun actuals vs. your sealed
   predictions (scored explicitly), red-team outcome, deviations, and your
   promote/hold/kill recommendation against the one-pager's gates —
   including a separate verdict for the `Schedule.t` slimming.

## Done means

Your final message ends with exactly one of:

- `E24 READY FOR REVIEW`
- `E24 BLOCKED: <reason>`
- `E24 STOP: <§4.6 stop condition>`

The orchestrator verifies (diff, focused tests, evidence audit), runs the
independent review, and decides. Rework via follow-up messages.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md` (orchestrator's
  sealed predictions — reading them contaminates yours), `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E24 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E24's surface. Adjacent footguns → journal follow-ups, not this
  diff. If you find a tap use that observers genuinely cannot express, do
  NOT work around it — record it verbatim in your journal; that is the
  one-pager's hold trigger and the orchestrator wants it raw.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e24/` must be committed.
