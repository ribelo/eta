# Objective: DX-E42a — Privacy moves (daemon, Expert, supervisor builders)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e42a`
- Branch: `research/dx-e42a-privacy-moves` (already checked out here; do not create others)
- Wave: EOP-audit hardening · Effort M · Risk low–med (namespace migration; JS track touched)
- Evidence IDs: `V-DX-E42A-*` (orchestrator log); your journal is the branch record

## Executor profile

A namespace-hygiene batch: three privacy moves that shrink the
application-facing surface and make the service-provider surface honest
about its status. The work is a mechanical migration (~170 lines across
lib/test/examples) plus care with mli restructuring and the law registry
(source spans move). Low design invention — the direction is fixed by
the audit verdict; the mechanics (exact module shape) are yours to
propose within the constraints below, and the review will judge them.

## Mission

Eta may be complicated inside; using Eta must feel beautiful — and a
surface that makes machinery look like application API is not beautiful.
Three moves from the EOP audit (§6.2–6.4, grill-adopted verbatim):

1. `Effect.daemon` is a public second execution model while the docs say
   runtime-owned daemon work should stay internal.
2. `Effect.Expert` is a pragmatic SPI that looks like normal library —
   and like an invitation to service-locating.
3. `supervisor_pure/lift/fail/bind/start/await/cancel/failures/check`
   are low-level builders documented as such; `Supervisor.scoped` and
   `Supervisor.Scope` are the user surface.

## Consumption model (V-DX-PRINC-1)

Eta is consumed primarily by EXTERNAL consumers. In-repo unusedness is
not evidence of unnecessity; frequency gates apply only absent a
structural need.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file. Law policy:
   `effect.mli` is census-complete; rows whose source spans move must be
   re-anchored in the same change.
2. `.scratch/research/eop-audit-2026-07-26.md` §6.2, §6.3, §6.4 — the
   three claims, verbatim.
3. `lib/eta/effect.mli` — the `daemon` val, the `Expert` submodule, the
   `supervisor_*` vals, and the header comment about the facade.
4. `lib/eta/supervisor.ml` + `supervisor.mli` — the real consumer of the
   builders.
5. `docs/services.md` — the current Expert escape-hatch framing.
6. `examples/daemon_drain.ml` — the one app-shaped daemon user.

## The change

**One SPI namespace.** `Effect.daemon` and `Effect.Expert` move to a
single, explicitly unstable home. You propose the mechanics (a
submodule, a sibling module in the `eta` library, or a separate public
library) — constraints: (a) it is ONE namespace, not several; (b) its
documentation carries these four sentences verbatim in substance: *this
is not application API; there is no compatibility guarantee; usage
requires justification at the runtime-package level; it is not for
application dependency injection*; (c) existing consumers (~10 lib
files / 6 packages + tests) migrate with minimal dependency churn —
they all already depend on `eta`.

**Supervisor builders → private.** The nine `supervisor_*` vals leave
the public mli entirely (private module used by `Supervisor`'s
implementation). If anything besides `Supervisor` and tests uses them,
STOP and report — that would be a design entanglement, not a migration.

**`Runtime.drain` stays** (out of scope; note it in the journal as
considered-and-kept per the grill verdict's silence).

**`examples/daemon_drain.ml`:** the audit's recommendation is that
long-lived processes belong to an explicit top-level application scope.
Rewrite the example to the recommended pattern (or delete it and point
the docs at the pattern) — do NOT leave it teaching `Effect.daemon` as
application API. If you judge an SPI-demonstrating example has value,
it must live under SPI framing, not in `examples/`; the review decides.

## Protocol

1. **Seal YOUR predictions** in `.scratch/research/dx/e42a/journal.md`
   BEFORE any code change: predicted SPI shape/mechanics, predicted
   migration size, predicted census/footgun deltas, predicted example
   outcome. Commit first. Never edit. (The orchestrator's set is sealed
   on master, V-DX-E42A-001 — do not read
   `.scratch/research/dx-journal.md`.)
2. **Docs-first:** the new SPI module's doc block (with the four
   sentences) and the mli deletions before the migration.
3. **Implement + migrate** (~170 lines; compiler-guided).
4. **Gates:**
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo test/signal_jsoo test/http_js
   ```
   (`lib/js_stream` and `test/js_jsoo` are in the migration surface —
   the mainline check is mandatory, not advisory.)
5. **Mechanical extras.**
   - **Census:** `Effect.mli` public vals/submodules before/after; SPI
     surface census; expect −10 vals −1 submodule, +1 SPI module.
   - **Footguns:** expect −1/+0.
   - **Law registry:** every daemon/Expert/supervisor row re-anchored
     to the new spans; the `Effect`-facade claims updated; no orphans.
   - **Red-team:** try to use the SPI from an application-shaped file —
     is anything in the new shape still *inviting* locator behavior, or
     does the namespace + doc make the wrong thing look wrong (T2)?
     Record the attempt.
   - **Behavior parity:** zero semantic change — the full suite is the
     proof; no behavior tests may change meaning (only namespaces).
6. **Dossier** (`.scratch/research/dx/e42a/dossier/`): the SPI doc
   block, the mli diff summary, the example before/after, census,
   law-registry diff, red-team note. PR-style review reads the change.
7. **Report** per the usual shape: gates, evidence vs. sealed
   predictions (scored), deviations, recommendation.

## Done means

Final message ends with exactly one of:

- `E42A READY FOR REVIEW`
- `E42A BLOCKED: <reason>`
- `E42A STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`,
  `docs/research/`, `.scratch/research/dx-prd-0001.md`,
  `.scratch/research/orchestrator-state.md`. Repo-wide searches must
  exclude fenced paths by glob.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E42a's surface: `daemon`, `Expert`, supervisor builders,
  their consumers/tests/law rows/docs. `Runtime.drain` is OUT of scope.
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e42a/` must be committed.
