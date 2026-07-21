# Objective: DX-E12 — `Effect.audit` / `Effect.describe` (blueprint introspection)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e12`
- Branch: `research/dx-e12-audit-describe` (already checked out here; do not create others)
- Phase: D (runtime & model) · Effort M · Risk low
- Evidence IDs: `V-DX-E12-*` (orchestrator log); your journal is the branch record

## Executor profile

GADT surgery plus evidence discipline: a capability-flags field on the
blueprint's `Custom` node, threaded through every leaf constructor;
then `audit`/`describe` walkers, property tests over a generated
blueprint class, and a golden manifest of 54 examples. The difficulty is
careful flag semantics (what each flag may claim) and honest docs — the
flags are a *static preflight*, not a runtime inventory, and the boundary
of that claim is the taste test.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Two needs
are met today by prose and discipline: teaching ("an `Effect.t` is a
blueprint; `Runtime.run` interprets it") and verification ("this handler
never sleeps"). The blueprint is already reified (`collect_names`
traverses it) — the introspection is just not exposed. T5: the blueprint
is a value — inspectable, printable, auditable.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/eta/effect_core.ml` lines ~55–125 — the 4-constructor GADT
   (`Pure`, `Fail`, `Custom`, `Map`, `Bind`), `make`, `preserve`,
   `collect_names`. `Custom` leaves are opaque `eval` functions with
   names but NO capability footprint — you add it.
3. Representative leaves to see the footprint sites: `sleep`, `log`,
   `metric_update`, `fork`/`daemon`, `with_resource`/`acquire_release`,
   `map_par`/`par`, `retry` (all are `make`/`preserve` users).
4. `lib/test/eta_test.ml{,i}` — where the assertions land.
5. `test/ppx_expansion/` and the E7 snapshot style — for the `describe`
   corpus discipline.

## The experiment (one-pager, from DX-PRD-0001 §E12)

```ocaml
type audit = {
  names           : string list;
  uses_clock      : bool;  emits_logs : bool;  emits_metrics : bool;
  has_concurrency : bool;  has_resources : bool; has_background : bool;
}
val audit    : ('a, 'err) t -> audit
val describe : ('a, 'err) t -> string  (* static tree; unforced
                                          continuations printed as <bind …> *)
```

Plus `Eta_test` assertions (`assert_no_clock`, `assert_pure_eff`, …) —
the vocabulary docs already use, made executable (T5). Static preflight,
**not** a runtime inventory: continuation nodes are not forced; flags are
conservative and the docs say which way each can err.

**Gates from the one-pager.** Promote on green properties + tutorial
rating ≥ 4. **Kill `audit`'s manifest role** if example flags mislead
more than inform — evidence feeds DX-E17.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Proof obligations: flag⇒behavior consistency on a *documented blueprint
class*, not on arbitrary lambdas. Working artifacts in
`.scratch/research/dx/e12/` **on this branch** (commit them):
`journal.md`, `report.md`, `redteam/`, `review/`.

## The honesty constraint (read twice)

Bind continuations cannot be forced — user lambdas are opaque ordinary
functions. Your docs MUST state precisely: flags cover the **static spine
plus declared footprints of library leaves**; a
`bind (fun x -> Effect.sleep …)` is invisible to `audit`. Every property
test generates blueprints from the documented class (pure/fail/map +
declared leaves), never from arbitrary lambdas. If you cannot state this
boundary crisply in the mli, the flags mislead — that is the kill
trigger for the manifest role; record it raw, don't paper over it.

## Protocol

1. **Seal your predictions** in `.scratch/research/dx/e12/journal.md`
   before any code change (`docs(dx-e12): seal predictions`).
2. **Docs-first.** `.mli` contracts for `audit`, `describe`, the flag
   meanings (each flag: what sets it, and which direction it can err),
   and the `Eta_test` assertions — before implementation.
3. **Implement the smallest change:** flags field on `Custom`; declare at
   every leaf (`preserve` INHERITS the inner effect's flags — union);
   `audit` ORs the static spine; `describe` prints the tree with
   `<bind …>` for unforced continuations.
4. **Gates** (from the worktree, exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo
   ```
   (`signal_jsoo` is expected-fail on master — do not touch it.)
5. **Mechanical extras.**
   - Property tests: generate blueprints from the documented class;
     flags consistent with execution against poisoned capabilities
     (`uses_clock = false` ⇒ runs with a poisoned clock;
     `emits_logs = false` ⇒ a recording logger stays silent).
   - `describe` snapshot corpus: pure chain, named leaves, nested
     `<bind …>`, concurrent shapes, the `fold`/`bind_error` compositions.
   - Golden manifest: `audit` of every `examples/` program as committed
     golden files (machine-generated, with a regeneration script).
   - `Eta_test` assertions: `assert_no_clock`, `assert_pure_eff`, and
     any others the mli vocabulary needs — executable.
   - Census: introspection cluster +2 vals / +1 public type / `Eta_test`
     +assertions; footguns +0 with the opaque-lambda trap recorded as
     disarmed-by-docs.
6. **Red-team pass** in `.scratch/research/dx/e12/redteam/`: (a) write
   the handler that "never sleeps" per `audit` but sleeps inside a
   `bind` lambda — show `audit`'s blind spot and whether the mli warned;
   (b) a `preserve`-wrapped composition — prove flag inheritance works
   (a wrapped `sleep` still flags `uses_clock`).
7. **Review packet** in `.scratch/research/dx/e12/review/`: the teaching
   A/B — `blueprint-prose.md` (the blueprint model taught from prose)
   vs `blueprint-describe.md` (the same lesson taught from a real
   `describe` output of a small program) — plus `QUESTIONS.md`
   ("what does `uses_clock = false` guarantee?" expecting the
   static-spine caveat).
8. **Report** in `.scratch/research/dx/e12/report.md`: gates, properties,
   corpus, manifest quality (do the flags match what a reader expects
   from each example's name? — the kill-gate input), census/footguns vs.
   predictions (scored), red-team outcomes, your promote/kill
   recommendation.

## Done means

Your final message ends with exactly one of:

- `E12 READY FOR REVIEW`
- `E12 BLOCKED: <reason>`
- `E12 STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E12 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E12's surface: the GADT flags, `audit`/`describe`, `Eta_test`
  assertions, tests, docs, the manifest. Do NOT touch `Schedule.t`,
  E19/E20 machinery, or examples' code (golden manifest is generated,
  not hand-edited).
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e12/` must be committed.
