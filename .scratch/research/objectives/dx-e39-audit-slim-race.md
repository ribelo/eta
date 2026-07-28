# Objective: DX-E39 — The E12 audit-slim race

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e39`
- Branch: `research/dx-e39-audit-slim-race` (already checked out here; do not create others)
- Wave: EOP-audit hardening · Effort M · Risk med (interpreter representation surgery)
- Evidence IDs: `V-DX-E39-*` (orchestrator log); your journal is the branch record

## Executor profile

A two-endpoint race with representation surgery and measurement. You will
delete code from the interpreter core (`Custom` node carries a
`capability_footprint` today), measure the cost it imposed, produce two
clean PR-reviewable endpoint diffs, and assemble a decision dossier. The
final call (which endpoint promotes) is the orchestrator's with independent
review — your job is evidence both sides can be judged on, plus your own
reasoned recommendation. Precision matters: the law registry (E22) pins
`effect.mli` census-completely, and `describe` output is snapshotted.

## Mission

Eta may be complicated inside; using Eta must feel beautiful — and what Eta
claims must be true. The EOP audit calls this surface the strongest removal
candidate in the library: `audit`'s own documentation admits it can both
over- and under-report. T5 counters: the blueprint is a value —
inspectable, printable, auditable. This race decides, with evidence, how
much of E12 survives that collision.

## Consumption model (V-DX-PRINC-1)

Eta is consumed primarily by EXTERNAL consumers. In-repo unusedness is not
evidence of unnecessity; frequency gates apply only absent a structural
need. Conversely, "users might want it" is not a defense either — a
structural need must be named. Apply this both ways when you census
consumers.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file. Note the **law
   policy**: `effect.mli` is census-complete; removing law-bearing prose
   requires registry updates (`.scratch/research/dx/e22/review/LAWS.md`)
   in the same change.
2. `.scratch/research/eop-audit-2026-07-26.md` §6.1 — the removal claim,
   verbatim.
3. `lib/eta/effect.mli` — `type audit`, `val audit`, `val describe`,
   `collect_names`, the `Expert.make` capability paragraph.
4. `lib/eta/effect_core.ml` — `capability_footprint`, `union_footprint`,
   the `Custom` node, `make`/`preserve` threading.
5. `lib/test/eta_test.mli` — the four assertions.
6. `.scratch/research/dx/e12/report.md` — what E12 promised at promotion.

## The race (both endpoints built, in order)

**Phase 0 — evidence before deletion.** Commit as
`.scratch/research/dx/e39/evidence/`:
- *Consumer map*: every use of `audit`/`describe`/`collect_names`/the four
  assertions classified (self-test / boundary check / doc ref / real).
- *Dependency map*: what besides `audit` reads the `footprint` and `names`
  fields — in particular whether runtime tracing depends on `names`
  propagation (the audit says `named` must stay for tracing; verify what
  that means mechanically before touching the field). Also: what is
  `all`'s "special introspection behavior" the audit mentions — find it,
  quote it.
- *Honesty audit*: every claim the current mli/docs make for
  `audit`/assertions, quoted with its hedge.
- *Cost baseline*: a construction-heavy microbenchmark (deep map/bind/
  preserve chains; use the existing `bench/` infrastructure) measuring
  allocated words and time for blueprint construction, master-side. This
  is the BEFORE number.

**Endpoint S — slim.** Delete: `type audit` + `val audit`;
`capability_footprint`/`union_footprint`/the `footprint` field and its
threading through `make`/`preserve`; all four `eta_test` assertions;
`Expert.make`'s capability declaration requirement; any `all` introspection
special-casing found above. Keep: `describe`, `collect_names` (verify they
are footprint-free by construction — `describe` renders `Custom` as opaque
leaf, `<bind …>` unforced). Migrate everything the gates build, including
law-registry rows for the deleted surface and the `blocking_common`
boundary check (migrate to an ordinary behavior test or drop with a
journal note).

**Endpoint R — remove.** On top of S, additionally delete public
`describe` and `collect_names` (the internal `names` mechanism stays iff
tracing needs it — per your dependency map). Migrate.

Build S first, gates green, commit. Then R on top, gates green, commit.
Two diffs, each independently reviewable: `master..S` and `S..R`.

**Phase 2 — cost measurement, AFTER side.** Re-run the Phase-0 benchmark
on the S tree. Report allocated-words and time deltas as percentages with
the machine noted. The pre-registered threshold: ≥ 10% construction
overhead makes cost a first-class argument for R.

## Gates (on BOTH endpoints)

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo test/signal_jsoo test/http_js
```

(JS track: F1 is closed, all four targets are green on master today — keep
them green. The dedicated `_build-mainline` dir is mandatory.)

## Regression / red-team

- **Snapshot parity:** `test/effect_introspection/snapshot_effect_describe.ml`
  output must be byte-identical on master and on S for the same corpus.
  The teaching tool must not notice the surgery.
- **Dishonesty probe:** on master, write the lie the old API permitted —
  an `Expert.make` leaf whose declared footprint contradicts its behavior
  (e.g. declares nothing, sleeps). Commit the probe; on S it must be
  unwritable by construction. Record both.
- **Law registry:** every deleted law-bearing claim removed from
  `LAWS.md` with its row disposition noted; surviving rows untouched.

## Review dossier (`.scratch/research/dx/e39/dossier/`)

For the orchestrator's decision review: the consumer map, dependency map,
honesty audit, cost measurement (before/after), both diffs' stats
(files/LoC), the snapshot-parity proof, the dishonesty probe, census delta
per cluster, footgun delta, and your recommendation with reasoning. The
dossier must let a reviewer decide WITHOUT trusting you — artifacts, not
adjectives.

## Protocol

1. **Seal YOUR predictions** in `.scratch/research/dx/e39/journal.md`
   BEFORE any code change: predicted endpoint winner, predicted cost
   bracket, predicted consumer classifications. Commit first. Never edit.
   (The orchestrator's own set is already sealed on master, V-DX-E39-001 —
   do not read `.scratch/research/dx-journal.md`; contamination ruins the
   dual-seal.)
2. Docs-first: the S-endpoint mli deletions/notes before the surgery.
3. Smallest diffs that achieve each endpoint; conventional commits;
   S and R as separate commits (or small commit series) for independent
   review.
4. `report.md` per the usual shape: gates on both endpoints, evidence vs.
   your predictions (scored), deviations, your endpoint recommendation.

## Done means

Your final message ends with exactly one of:

- `E39 READY FOR REVIEW`
- `E39 BLOCKED: <reason>`
- `E39 STOP: <§4.6 stop condition>`

The orchestrator runs the independent review and decides S vs R. The
losing endpoint stays on the branch as provenance.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E39's surface: `Effect.audit`/`describe`/`collect_names`,
  footprints, the four assertions, `Expert.make`'s capability parameter,
  and their direct consumers/tests/law rows/docs. If you find the `names`
  mechanism entangled with tracing beyond what the dependency map
  predicted, STOP and report — that boundary is the experiment's fault
  line.
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e39/` must be committed.
