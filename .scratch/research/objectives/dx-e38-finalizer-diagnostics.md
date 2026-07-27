# Objective: DX-E38 — Finalizer diagnostics structure: kill the string, keep the value

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e38`
- Branch: `research/dx-e38-finalizer-diagnostics` (already checked out here; do not create others)
- Phase: hardening wave (EOP audit §4.6) · Effort M · Risk low–med (type-level change, wide mechanical migration) · **P0-5**
- Evidence IDs: `V-DX-E38-*` (orchestrator log); your journal is the branch record

## Executor profile

Type-level OCaml care (a GADT existential + equality semantics) plus a
wide, mechanical consumer migration plus parity discipline. The hard
part is one design decision (equality) and not breaking render parity
anywhere; the long part is the match-site migration.

## Mission

Today, a typed finalizer failure is flattened to a string at
`finalizer_of_cause` — the error value dies, and telemetry gets
`"<typed failure>"` unless someone hand-rendered earlier. The human's
standing note on this class of design: **"I can't stand strings."**
`Cause.die` already carries structure; `Cause.Portable` already exists
to do string materialization where that's actually the job. The Fail
side joins the present: the value survives, the printer travels with it.

## Read first (in order)

1. `AGENTS.md`.
2. `lib/eta/cause.mli` + `cause.ml` — `Finalizer.t`, `die`, `Portable`,
   `finalizer_of_cause`, `equal`/`diagnostic_equal`/`pp`.
3. `lib/eta/effect.mli` — the `error_pp` injection points (E25);
   `lib/ppx/ppx_eta.ml`'s deriver output shape (`pp_err`, E7).
4. `test/core_common/cause_render_common_suites.ml` — E4's render
   corpus (your parity oracle).
5. `test/otel_common/cause_json_common_suites.ml` — the encoding
   consumer.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Artifacts in `.scratch/research/dx/e38/` **on this branch** (commit
them): `journal.md`, `report.md`, `redteam/`.

## The experiment

**Shape (decided upstream).** Same-domain `Cause.Finalizer.Fail`
becomes an existential payload with printer (GADT — final form yours:
bare existential case or a small record wrapper). `Cause.Portable.
Finalizer.Fail` STAYS string-materialized — materialization happens via
the payload's pp at the `of_cause` boundary (that's Portable's job).

The diagnostic-record alternative (kind/message/attrs) is **rejected**:
it flattens at construction AND keeps string kinds. One line in your
journal.

**Semantics to pin.**
1. **Render parity**: `Cause.pp`/`pp_compact` produce IDENTICAL strings
   for existing cases — today's string IS the pp output, and the
   `<typed failure>` default persists where no `error_pp` is
   registered. E4's corpus is the oracle: unchanged, or every delta
   individually justified in the report.
2. **Equality**: same-domain `equal`/`diagnostic_equal` compare
   rendered forms via pp (document the rule in the mli); structure
   otherwise preserved. This is THE design decision — own it.
3. **Meaningful rendering where printers exist**: with an `error_pp`
   (E25) or derived `pp_err` (E7), a typed finalizer failure renders
   with its kind+payload, not `"<typed failure>"`. One golden test
   proving the pipeline end-to-end (E7-derived printer on a release
   failure → rendered `Finalizer.Fail`).
4. **Value survival**: a consumer holding the concrete type can
   classify the payload (a test demonstrating extraction/matching on
   the existential at the producing call site).
5. **jsoo**: pure-OCaml GADT — state portability; no substrate question.

**Migration.** Construction site (`finalizer_of_cause`), `Cause`'s
pp/equal functions, otel/JSON encoding, supervisor/async/resource/
render suites. Mechanical but wide; existential unpacking syntax at
match sites.

**Census/footguns.** Payload shape change (no new vals); +0 footguns.
Law-registry rows updated for every changed claim (exact spans).

## Gates

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo test/otel_common --force
```

(Adjust the otel target to the real directory.) Fix-forward ≤ 3
attempts per failure class, then BLOCKED.

## Protocol

1. **Seal your predictions** in `journal.md` (final GADT form, equality
   rule, parity outcome, census delta, review outcome) — commit before
   code (`docs(dx-e38): seal predictions`). Never edit after.
   (Dual-sealing: orchestrator's set is inherited on master; do not read
   it — fence below.)
2. **Docs-first**: the new `Cause.Finalizer` mli section (payload,
   equality rule, the default-render rule) before implementation.
3. Implement, migrate, prove parity.
4. Gates as above.
5. **Mechanical extras**: the end-to-end golden test (pin 3), the
   extraction test (pin 4), E4 corpus result, law rows, census delta.
6. **Red-team pass** in `redteam/`: (a) a release failure with NO
   `error_pp` — assert the default render is unchanged (no regression
   for printer-less errors); (b) a release failure WITH a derived
   `pp_err` — assert meaningful structure; (c) try to break equality:
   two different error values whose pp outputs collide — assert the
   documented equality rule handles it honestly (and state the rule's
   limit).
7. **Report**: shape, equality rule + justification, parity evidence,
   migration, census/footgun actuals vs. predictions (scored),
   red-team outcome, recommendation.

## Done means

- `E38 READY FOR REVIEW`
- `E38 BLOCKED: <reason>`
- `E38 STOP: <§4.6 stop condition>`

Orchestrator verifies and runs the adversarial review. Rework via
follow-ups.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E38's surface: `Cause` + its consumers. No `Effect.t` error
  parameter changes, no third error type, no otel exporter redesign.
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e38/` must be committed.
