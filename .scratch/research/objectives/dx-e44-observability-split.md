# Objective: DX-E44 — Observability full split (`eta_observability`)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e44`
- Branch: `research/dx-e44-observability-split` (already checked out here; do not create others)
- EOP hardening wave, item 11/14 · Effort L · Risk med (package-boundary surgery + large mechanical migration)
- Evidence IDs: `V-DX-E44-*` (orchestrator log); your journal is the branch record at `.scratch/research/dx/e44/journal.md`

## Executor profile

Package-boundary surgery plus a large mechanical migration: carve a new
opam package out of `lib/eta`, keep the dependency direction strictly
one-way, migrate ~510 call lines across every package, and re-tier the
package docs. The difficulty is dependency-direction discipline and the
fiber-local key seam, not design invention: the boundary below is the
contract. Docs-first; no shim modules; delete old paths.

## Mission

Eta may be complicated inside; using Eta must feel beautiful — and
*installing* Eta must stay honest. The audit's charge (V-DX-EOP-AUDIT):
`Effect` must not simultaneously be the effect, the tracer, the logger, the
metrics DSL, and the context-propagation framework. Root `eta` keeps only
the interpreter's minimal contract; everything a user *calls* to observe
moves to `eta_observability`. Install only what you use (AGENTS.md package
boundary policy).

## Consumption model (V-DX-PRINC-1)

Eta is consumed externally. In-repo unusedness is NOT evidence of
unnecessity. Frequency gates apply only absent a structural need.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file. Nix-only gates, no
   shims, delete old paths, break loudly, conventional commits, law
   registry policy for law-bearing mli prose.
2. `lib/eta/capabilities.mli` — the contract payload types (stays in root).
3. `lib/eta/runtime_observability.ml` — the fiber-local keys (THE CRUX).
4. `lib/eta/effect_observability.ml` — the DSL implementation (moves).
5. `lib/eta/effect.mli` lines ~730–1060 — the DSL surface (moves).
6. `docs/packages.md` — current tiers; you will re-tier (48 → 49 packages).
7. `lib/otel/dune` — a consumer that must repoint.
8. `.scratch/research/dx-ledger.md` E44 entry — the registered intent.

## Method

Evidence-based-coding:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
The design is decided below; skip hypothesis-space theatre. Proof
obligations: (1) root never depends on the SDK — prove by dune dependency
direction, not prose; (2) zero runtime-cost delta — bench watchlist parity,
same `Custom`-leaf mechanism; (3) migration completeness — zero stale
references; (4) the jsoo single-package claim — verified by mainline gates
or honestly held.

## The experiment

**Feasibility basis (orchestrator-measured, verify first).** The blueprint
ADT is `Pure | Fail | Custom | Map | Bind`; every observability leaf is
already a `Custom` closure with no interpreter coupling. Zero observability
duplication exists in `lib/jsoo`/`lib/js`; `Runtime_contract` is the
substrate seam. The split should be movable without touching runtime
execution at all.

**Moves to `eta_observability`** (new package, public library
`eta_observability`, top module `Eta_observability`):
- Modules: `Logger`, `Meter`, `Tracer` (incl. in-memory impls),
  `Log_level`, `Trace_context`.
- The full `Effect`-level DSL (~29 vals): `log`, `logf`,
  `log_trace..log_fatal`, `annotate`, `annotate_all`, `annotate_all_lazy`,
  `annotate_logs`, `with_minimum_log_level`, `intercept_log`, `with_logger`,
  `with_tracer`, `metric_update`, `metric_counter`, `metric_gauge`,
  `metric_frequency`, `metric_histogram`, `metric_summary`, `metric_timer`,
  `metric`, `metric_updates`, `metric_updates_lazy`, `intercept_metric`,
  `named`, `fn`.

**Stays in root `eta`** (the interpreter's minimal contract):
- `Capabilities` (contract payload types the interpreter consumes:
  `log_record`, `span_info`, `metric_point`, `log_level` type,
  `span_status`, `span_kind`, `trace_context` type).
- `Runtime_contract`, `Spi.Expert`.
- The interpreter's minimal diagnostic write path (defect→span annotation
  machinery; `die_context` handling).

**THE CRUX — the fiber-local key seam.** `runtime_observability.ml` holds
keys read by BOTH the core defect path AND the DSL leaves (`log_attrs_key`,
`minimum_log_level_key`, interceptor keys, `die_context`, `active_span_key`,
`sampled_key`, `trace_context_key`). Resolve the seam docs-first, with this
guidance: keys the interpreter itself writes/reads are interpreter contract
(stay, exposed to the SDK through `Spi` if needed); keys that exist only to
serve the DSL move. At most one Spi-exposed shared key. **If root ends up
depending on SDK concepts, that is the hold trigger — stop and report raw.**

**Module shape.** Recommended: flat root surface mirroring today's names
(`Eta_observability.named`, `Eta_observability.log_info`, …) for a
sed-class migration, with capability impls as submodules. Alternative
(`Log`/`Span`/`Metric` submodules) is your docs-first call IF you argue it
beats sed-class migration on T1 — record the decision and rationale in your
journal.

**PPX consequence.** `[%eta.sync]`/`[%eta.result]` expand into
`Effect.fn`/`Effect.named`; those move, so generated code gains an
`eta_observability` dependency. Repoint the expansions, update snapshots,
flag as breaking in the changelog draft.

## Protocol

1. **Seal your predictions** in `.scratch/research/dx/e44/journal.md`
   (`Predictions (sealed)`): expected census delta, expected seam
   resolution, the two likeliest things to break. Commit before any code
   change (`docs(dx-e44): seal predictions`). Never edit afterward. (The
   orchestrator's own sealed predictions are already on master and fenced —
   do not read `.scratch/research/dx-journal.md`.)
2. **Docs-first.** Write the new package's boundary doc and the moved
   `.mli` contracts before implementation, including the seam resolution.
   Re-tier `docs/packages.md` (48 → 49) — and if you touch the `eta_stream`
   row, fix its "backend-neutral" phrasing (follow-up F10) in the same
   edit.
3. **Implement the smallest change.** Move compilation units, repoint
   dependents (`eta_otel`, `eta_test`, `eta_http*`, …), migrate every call
   site the gates build. No shim modules forwarding old paths.
4. **Gates** (exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo
   ```
   Fix-forward up to three attempts per failure class, then BLOCKED.
5. **Mechanical extras.**
   - Dependency-direction proof: `dune describe` (or equivalent) showing
     `eta` has no dependency on `eta_observability`, and the SDK's closure
     contains `eta` only. Commit the output.
   - Bench parity: `nix develop -c bash bench/run.sh --quick` — watchlist
     delta within noise (< 2%); the mechanism is unchanged, so anything
     larger needs an explanation, not a shrug.
   - Census: `Effect.mli` vals before/after (orchestrator pre-count: 119 →
     85±3); package count 48 → 49; dependency graph before/after.
   - Law registry: any new/moved law-bearing mli prose gets rows in
     `.scratch/research/dx/e22/review/LAWS.md` per AGENTS.md policy.
   - CHANGELOG draft fragment (orchestrator assembles).
6. **Red-team.** (a) From a root-only dependency context, attempt to call
   an observability combinator — must fail at build time (package absence
   IS the fence); (b) attempt to make the SDK depend on something that
   would cycle back through root — dune must reject; (c) root-only consumer
   supplies a hand-rolled `Capabilities.tracer` record; a defect must still
   annotate the span — the interpreter's write path works with the SDK
   absent. Commit probes + verdicts under `.scratch/research/dx/e44/redteam/`.
7. **Review packet.** Per V-DX-AMEND-3 the review is PR-style, not snippet
   theater: assemble a `review/POINTERS.md` listing the merge-range diff,
   the new boundary doc, the seam resolution, and the census — the reviewer
   reads the actual change. Plus your self-assessment of the weakest spot.
8. **Report** in `.scratch/research/dx/e44/report.md`: gates summary,
   seam decision, census/footgun actuals vs. sealed predictions (scored),
   red-team outcomes, bench parity, deviations, and your
   promote/hold/kill recommendation against the gates below.

**Gates for promote.** Promote: dependency direction proven one-way, all
gates green, parity within noise, seam resolved without root→SDK
dependency, jsoo single-package verified. Hold: the seam forces root to
depend on SDK concepts, or jsoo requires a duplicated SDK (substrate
divergence). Kill: the interpreter's minimal contract proves unstateable
without the SDK (record evidence; the wave decision reverts to
namespace-split).

## Done means

Your final message ends with exactly one of:

- `E44 READY FOR REVIEW`
- `E44 BLOCKED: <reason>`
- `E44 STOP: <§4.6 stop condition>`

The orchestrator verifies (diff, focused tests, evidence audit), an
independent oracle reviews PR-style, rework rounds go back through the
intermediary (to the reviewer of record).

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md` (orchestrator's
  sealed predictions), `docs/research/`, `.scratch/research/dx-prd-0001.md`
  beyond the E44 entry quoted in the ledger,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E44's surface. Adjacent footguns → journal follow-ups.
  F10 (eta_stream phrasing in docs/packages.md) IS in scope as noted.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e44/` must be committed.
