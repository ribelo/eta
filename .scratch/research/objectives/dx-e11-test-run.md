# Objective: DX-E11 — `Eta_test.Run`: one golden-record test runtime

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e11`
- Branch: `research/dx-e11-test-run` (already checked out here; do not create others)
- Phase: D (runtime & model) · Effort L · Risk med
- Evidence IDs: `V-DX-E11-*` (orchestrator log); your journal is the branch record

## Executor profile

The largest Phase D assignment: a golden-record test runtime — one entry
point returning one inspectable record (exit, logs, spans, metrics,
sleeps, pending fibers, finalizer events), plus a printer that makes a
failure print the whole execution. Three separable builds, in order:
(1) the record + `run` over existing in-memory sinks and E19 scoped
overrides; (2) test-only runtime accounting (fiber registry + finalizer
journal) with an accounting-neutrality proof; (3) the golden printer.
Each phase is independently mergeable; the kill criteria are scoped
(accounting can die alone; the printer can kill the whole).

## Mission

Eta may be complicated inside; using Eta must feel beautiful. The hard
questions in an effect system are not about the result: *was the sibling
cancelled? did the finalizer run? did retry sleep 10, 20, 40? is any
fiber still pending? was the suppressed failure preserved?* Today they
require assembling `Test_clock`, sinks, `Async.fork_run`, and `Expect`
by hand — and pending fibers / finalizer events have no public answer at
all. Prior art: polysemy `runOutputMonoid` — run an effect into data.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/test/eta_test.ml{,i}` — today's assembly (`Test_clock`, `Async`,
   `Expect`, `Test_random`, E19-era `with_*` helpers).
3. `lib/eta/logger.mli`, `tracer.mli`, `meter.mli` — the `in_memory`
   sinks; the record's first three fields already have homes.
4. `lib/eta/effect.mli` — E19's `with_clock`/`with_logger`/`with_tracer`
   (your internals compose these instead of bespoke runtimes).
5. `lib/eta/runtime_core.ml` — the `drain_waiter` seam; your accounting
   instrumentation lives at the contract level, test-only.
6. `.scratch/research/dx/e19/report.md` and `dx/e20/report.md` — the
   machinery you compose.

## The experiment (one-pager, from DX-PRD-0001 §E11)

```ocaml
module Eta_test.Run : sig
  type ('a, 'err) outcome = {
    exit             : ('a, 'err) Exit.t;
    logs             : Logger.record list;
    spans            : Tracer.span list;
    metrics          : (* meter updates *) ;
    sleeps           : Duration.t list;        (* observed, in order *)
    pending_fibers   : fiber_info list;        (* NEW: runtime accounting *)
    finalizer_events : finalizer_event list;   (* NEW: runtime accounting *)
  }
  val run : ?clock:Test_clock.t -> ?seed:int -> … -> ('a,'err) Effect.t -> ('a,'err) outcome
  val expect_no_pending_fibers : _ outcome -> unit
  val expect_sleeps            : Duration.t list -> _ outcome -> unit
  val expect_finalizers        : int -> _ outcome -> unit
end
```

- `sleeps` comes from the virtual clock: backoff asserted exactly, no
  wall time.
- `pending_fibers` / `finalizer_events` need opt-in runtime accounting,
  test-runtimes only; production cost must stay zero (feasibility is the
  first question).
- The record is golden: `Alcotest.testable`s and a printer so a failure
  prints the whole execution, not a boolean.

**Gates from the one-pager.** Promote the record even if accounting slips
(exit+logs+spans+metrics+sleeps already wins). **Kill `pending_fibers`
specifically** if it cannot be test-only/zero-cost — recorded as a
runtime design finding. **Kill the whole** if the golden printer is
unreadable at corpus size.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Determinism is the contract: same program + same runtime construction ⇒
same outcome record, every run. Working artifacts in
`.scratch/research/dx/e11/` **on this branch** (commit them):
`journal.md`, `report.md`, `redteam/`, `review/`.

## Protocol

1. **Seal your predictions** in `.scratch/research/dx/e11/journal.md`
   before any code change (`docs(dx-e11): seal predictions`).
2. **Docs-first.** `.mli` for the module: the outcome record's field
   meanings, the determinism contract, what `pending_fibers` counts
   (daemons are owned work, not leaks — say it), what
   `finalizer_events` records (success/failure, order), and the
   accounting-neutrality claim.
3. **Phase 1 — record + run.** Compose in-memory sinks, `Test_clock`,
   E19 scoped overrides. `run` returns the record; `expect_*` helpers.
4. **Phase 2 — accounting.** Test-only fiber registry + finalizer
   journal at the contract level. Then the accounting-neutrality proof:
   run the existing suite under the accounting runtime, exits identical
   (script committed). If accounting cannot be test-only/zero-cost,
   kill it per the gate and record the finding — the record still ships.
5. **Phase 3 — golden printer.** `Alcotest.testable`s + `pp`: a failure
   prints exit, then the ordered event log (sleeps, logs, spans,
   finalizers), then pending fibers. Corpus-readable at 6 scenarios.
6. **Gates** (from the worktree, exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo
   ```
   (`signal_jsoo` is expected-fail on master — do not touch it.)
7. **The six canonical golden scenarios**, all executable:
   sibling cancelled on failure; finalizer ran on interruption; retry
   slept exactly [10; 20; 40]; span closed on defect; suppressed
   finalizer preserved in the cause; race-loser resource released.
8. **Red-team pass** in `.scratch/research/dx/e11/redteam/`: (a) a
   deliberately broken variant of scenario 3 (retry slept [10;20;30])
   — the golden output must diagnose it on the message rubric
   (what/where/what-next), verbatim in the report; (b) a
   daemon-leaving program — show `pending_fibers` distinguishes owned
   daemons from leaked fibers, or document why it can't.
9. **Review packet** in `.scratch/research/dx/e11/review/`: W6 one-call
   (`w6-run.ml`) vs the E19-era assembly (reference the E19 packet's
   `w6-new.ml` shape); plus the broken-test golden output
   (`broken-output.txt`) for the rubric rating.
10. **Report** in `.scratch/research/dx/e11/report.md`: gates, scenario
    evidence, accounting-neutrality proof, census/footguns vs.
    predictions (scored), red-team outcomes, printer readability
    self-rating with the corpus, and your promote/kill recommendation —
    with `pending_fibers` argued separately per the gate.

## Done means

Your final message ends with exactly one of:

- `E11 READY FOR REVIEW`
- `E11 BLOCKED: <reason>`
- `E11 STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E11 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E11's surface: `Eta_test`, test-only accounting, docs, tests.
  Do NOT add accounting to the production runtime path, do NOT touch
  `Schedule.t`, E19/E20 machinery, or the existing suites' semantics.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e11/` must be committed.
