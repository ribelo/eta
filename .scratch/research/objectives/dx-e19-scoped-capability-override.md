# Objective: DX-E19 — Scoped capability override (`with_clock` / `with_random` / `with_logger` / `with_tracer`)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e19`
- Branch: `research/dx-e19-scoped-capability-override` (already checked out here; do not create others)
- Phase: D (runtime & model) · Effort M · Risk med · **flagship**
- Evidence IDs: `V-DX-E19-*` (orchestrator log); your journal is the branch record

## Executor profile

Semantics-heavy runtime work: generalize the existing fiber-local binding
machinery (`local_with_binding`, 19 uses, powering `annotate_logs` etc.)
to the four runtime capabilities, on both backends, with the full edge
matrix tested (four exit kinds × fork × `par` isolation × composition).
The difficulty is semantic precision and doc discipline — the kill gate
is a *doc budget*, not a test. Import provenance: polysemy
`reinterpret`/`local` (cite in the journal).

## Mission

Eta may be complicated inside; using Eta must feel beautiful. A fake clock
for one assertion should cost one combinator, not a bespoke runtime.
This is the idiomatic Eta answer to polysemy's local reinterpretation —
and it is NOT an environment: `zio-boundaries.md` allows fiber-local
state exactly when Eta owns the invariant, and runtime services are that
invariant. Never touches application dependencies; this is not `R`
through the back door.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/eta/runtime_contract.ml` — `local_with_binding` (rank-2) and how
   leaves consult `frame.runtime.now_ms` / `frame.runtime.sleep`.
3. `lib/eta/effect_observability.ml` — the `annotate_logs` /
   `with_minimum_log_level` / `with_context` / `with_error_pp` pattern you
   are generalizing: binding semantics (inherit at fork, restore on exit,
   sibling isolation) and their doc voice.
4. `lib/eta/capabilities.mli` — `tracer` and `logger` are **class types**;
   **`clock` does not exist** — you introduce it (the `?now_ms`/`?sleep`
   pair is documented in `lib/eta/runtime.mli` as "one monotonic
   runtime-clock pair").
5. `lib/test/eta_test.ml{,i}` — `Test_clock` today; the one-pager wants
   `Effect.with_clock (Test_clock.as_capability c) program` to work.
6. `docs/zio-boundaries.md` — the fiber-local rule this satisfies.

## The experiment (one-pager, from DX-PRD-0001 §E19)

```ocaml
val with_clock  : Capabilities.clock  -> ('a, 'err) t -> ('a, 'err) t
val with_random : Capabilities.random -> ('a, 'err) t -> ('a, 'err) t
val with_logger : Capabilities.logger -> ('a, 'err) t -> ('a, 'err) t
val with_tracer : Capabilities.tracer -> ('a, 'err) t -> ('a, 'err) t
```

Fiber-local, dynamically scoped; consulted by the corresponding leaves
(`now_ms`/`sleep`/`delay`/`timed`/`timeout*`/`retry`/`repeat` for clock;
`Random.*`; `log*`; `named`/`fn` spans).

**Semantics & edges (the substance).**
- *Inheritance:* children inherit the binding at fork (like
  `annotate_logs`); no join-merge; restore on success, typed failure,
  defect, and cancellation.
- *Composition:* innermost binding wins; nesting and sibling isolation
  rules written into the mli and docs, with examples — `par` branches
  must not leak overrides into each other (test).
- *Interplay:* `with_logger` replaces the sink; `annotate_logs` (attrs)
  and `with_minimum_log_level` (filter) are orthogonal and compose;
  DX-E20's future `intercept_log` transforms before the sink — the order
  is documented.
- *jsoo (T10):* pure data swaps over fiber-local cells; jsoo runtime
  locals already work (proven in E26).

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Proof obligations: the full edge matrix below, executable. The semantics
are the contract; the implementation is the pattern you already have.

Working artifacts in `.scratch/research/dx/e19/` **on this branch**
(commit them): `journal.md`, `report.md`, `redteam/`, `review/`.

## Protocol

1. **Seal your predictions** in `.scratch/research/dx/e19/journal.md`
   before any code change (`docs(dx-e19): seal predictions`).
2. **Docs-first.** Write the `.mli` contracts for the four `with_*`
   combinators and the new `Capabilities.clock` type before implementing.
   Each must state, within budget: fiber-local dynamic scope; inherit at
   fork, no join-merge; restore on all four exit kinds; innermost wins;
   `par` sibling isolation; **consulted at leaf call time** (an override
   does not retroactively change an in-flight sleep or an open span); a
   daemon spawned inside the scope keeps its fork-time binding after the
   scope exits. If these caveats do not fit the doc budget, that is the
   one-pager's kill condition — record it, do not paper over it.
3. **Implement** the smallest change: `Capabilities.clock` type, the four
   combinators over `local_with_binding`, leaf consultation,
   `Test_clock.as_capability` (or the honest equivalent you defend in the
   journal).
4. **Gates** (from the worktree, exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo
   ```
   (`signal_jsoo` is expected-fail on master — do not touch it.)
5. **Mechanical extras — the edge matrix, all executable:**
   - restore on success / typed failure / defect / interruption;
   - fork-inherit; sibling isolation under `par` (override in one branch
     invisible in the other, both directions);
   - innermost-wins nesting; restore-to-outer on inner exit;
   - clock override observed by `sleep` and `timeout` (fake clock fires
     deterministically, no wall time);
   - `with_logger` sink replacement; composition with `annotate_logs`
     (attrs) and `with_minimum_log_level` (filter) — order documented
     and tested;
   - jsoo parity for at least clock + logger.
   - Census: observability cluster +4 vals, Capabilities +1 type;
     footguns +0 with the three trap candidates recorded as disarmed-by-
     docs.
6. **Red-team pass** in `.scratch/research/dx/e19/redteam/`: (a) write the
   test that *expects* a `par` sibling to see the override — show it
   can't, and that the mli says so; (b) start a `sleep` under the real
   clock, override mid-flight, show the sleeping fiber is unaffected
   (consult-at-call-time) and the docs said so; (c) a daemon spawned
   inside the scope outlives it — record what binding it sees and
   whether the mli warned.
7. **Review packet** in `.scratch/research/dx/e19/review/`: W6 (prove a
   retry slept exactly 10/20/40 ms without wall-clock) written both ways —
   `w6-old.ml` (test-runtime assembly) vs `w6-new.ml` (scoped override);
   plus the teach-back prompt in `QUESTIONS.md`: "where does the fake
   clock stop applying?" and "a `par` sibling needs the same fake clock —
   what do you write?"
8. **Report** in `.scratch/research/dx/e19/report.md`: gates, edge-matrix
   results, census/footguns vs. predictions (scored), red-team outcomes,
   the doc-budget audit (line counts for the caveats — the kill gate's
   input), and your promote/kill recommendation.

## Done means

Your final message ends with exactly one of:

- `E19 READY FOR REVIEW`
- `E19 BLOCKED: <reason>`
- `E19 STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E19 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E19's surface. Do NOT add `intercept_*` (that's E20), do NOT
  migrate existing `annotate_logs`/`with_minimum_log_level` to the new
  machinery beyond what the interplay docs require, do NOT touch the four
  global counters or `Schedule.t` (E24b territory — journal notes only).
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e19/` must be committed.
