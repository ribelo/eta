# DX-E44 observability split journal

## Predictions (sealed)

Sealed before production code, package metadata, or package documentation was
changed. This section is immutable after the commit
`docs(dx-e44): seal predictions`.

### Baseline verified

- `lib/eta/effect_core.ml` defines exactly `Pure | Fail | Custom | Map | Bind`;
  observability operations are implemented as `Custom` evaluators through
  `Effect_core.make`/`preserve` (apart from pure constructors and convenience
  aliases).
- `lib/jsoo` contains no observability implementation. `lib/js` only re-exports
  the current root `Log_level` and `Trace_context` modules; it does not duplicate
  the runtime or DSL.
- Baseline census: 119 `val` declarations in `lib/eta/effect.mli`, 48 root opam
  package files, and no `eta_observability` public library.
- The required read-first path `.scratch/research/dx-ledger.md` is absent in this
  worktree. The similarly named `docs/research/dx-ledger.md` was not substituted
  because `objective.md` explicitly forbids reading `docs/research/`.

### Expected result

1. The package census will become 49, with one Batteries package named
   `eta_observability`, one public library of the same name, and the top module
   `Eta_observability`.
2. The public API will be flat (`Eta_observability.named`,
   `Eta_observability.log_info`, and so on). This is expected to minimize the
   migration to path replacement and preserve current call shape better than
   introducing `Log`/`Span`/`Metric` submodules.
3. A literal full split of the current observability surface is expected to move
   40 `Effect` vals, producing 79 root `Effect.mli` vals rather than the
   orchestrator's approximate `85±3`. The likely source of the difference is
   the advanced tracing/context surface plus `with_error_pp`,
   `suppress_observability`, and `here_attr`, which are present in the current
   implementation but omitted from the objective's approximate 29-val list.
   The implementation will follow the semantic boundary rather than target a
   count.
4. The root package will have no Dune or opam dependency on
   `eta_observability`; `eta_observability` will depend directly on `eta`.
   Packages that call the moved SDK will depend on both as required.
5. The DSL will continue to construct the same `Custom` leaves. No interpreter
   execution branch or blueprint constructor should change, so runtime
   observability watchlist results should remain within 2% noise.

### Expected fiber-local seam

- Interpreter-owned or interpreter-read state remains private in root:
  `active_span_key`, `sampled_key`, `trace_context_key`, `die_context_key`, the
  capability override keys, and the log/metric scope and interceptor keys used
  by daemon diagnostics or `Spi.Expert` emissions.
- SDK-only code will manipulate that state through narrow `Spi.Expert`
  operations. No raw key is expected to be exposed, satisfying the "at most one"
  limit with zero exposed shared keys while preserving daemon log attributes,
  filtering, and interceptor behavior.
- Root-owned private noop logger/tracer/meter capabilities will replace root's
  current dependency on the public implementation modules. Root's minimal W3C
  trace-context validation/sampling needed by span parenting will remain a
  private interpreter helper; the moved public `Trace_context` API will build on
  root substrate helpers rather than create a root-to-SDK edge.
- If this cannot be stated without importing an SDK module into root, the
  objective's hold trigger applies.

### Two likeliest break classes

1. Root-private coupling will surface first: `runtime_core.ml` currently uses
   `Logger.noop`, `Meter.noop`, and `Tracer.noop`; `runtime_instrument.ml` uses
   `Trace_context`; and `effect_supervisor_scope.ml` calls
   `Effect_observability.named`. Removing those modules without changing runtime
   semantics is the highest-risk seam work.
2. Mechanical dependency completeness will break next: PPX expansions currently
   emit `Eta.Effect.fn`/`named`, while HTTP, OTel, AI, tests, benches, examples,
   and JS facade re-exports rely on old paths. Missing one package dependency or
   generated snapshot is expected to appear as an unbound-module or unavailable
   library failure, especially in the mainline js_of_ocaml gate.

### Evidence that would overturn these predictions

- Any root Dune closure containing `eta_observability`.
- A required SDK key/type that cannot be expressed in `Capabilities`,
  `Runtime_contract`, or a narrow root `Spi.Expert` operation.
- A js_of_ocaml-specific observability implementation or duplicated SDK.
- A repeatable runtime watchlist regression above 2% after controlling for
  benchmark noise.

## Baseline evidence

The immutable predictions above were committed as `027d5500`. Baseline census,
dependency graph, and focused runtime-observability benchmark artifacts are in
`evidence/`. The exact full quick benchmark failed twice on a pre-existing
TypeScript Effect API mismatch (`Effect.with_scope` is unavailable); the raw
failure is preserved without changing that adjacent benchmark implementation.

## Docs-first boundary decision

- Selected the flat SDK surface. It preserves the current combinator call shape
  and keeps the mechanical migration auditable; `Log`/`Span`/`Metric` nesting
  would add call-site structure without changing ownership or invariants.
- Root owns every runtime-local key it reads. The SDK receives behavior through
  `Spi.Expert` functions rather than raw keys, so the exposed shared-key count is
  zero. This deliberately preserves scoped daemon logging and SPI metric
  interception instead of weakening those protocols to make the split easier.
- The public modules `Logger`, `Meter`, `Tracer`, `Log_level`, and
  `Trace_context` move wholesale. Private noop capabilities and minimal
  trace-context sampling/validation remain interpreter substrate, not public
  root SDK concepts.
- The new interface moves all 40 current observability vals, including the
  advanced trace-context surface and the three vals omitted from the approximate
  objective census. Existing executable-law registrations were repointed to the
  moved contract; mixed capability row R88 was split into root R88a and SDK R88b
  so each source pointer names exactly one package boundary.

## Implementation and migration

- Root `Effect.mli` now has 79 vals and `Eta_observability` has 40. The root
  effect error parameter exposes the covariance already present in the private
  representation so separately compiled polymorphic SDK constants remain
  reusable.
- Root private `Runtime_capabilities` and `Runtime_trace_context` modules replace
  dependencies on the moved public implementation modules. `Spi.Expert` exposes
  behavioral SDK operations but no local keys.
- The first seam review found that metric points were being built before the
  runtime's metrics-enabled check. The implementation was fixed forward: single
  points use the existing gated `record_metric`, and batches cross the seam as a
  thunk evaluated only after admission with one shared timestamp.
- All installable libraries, tests, examples, PPX expansions/snapshots, and
  benchmark watchlists were migrated without aliases. Direct Dune and opam
  dependencies were added only to packages compiling or re-exporting the SDK.
- The four required build/test gates passed after fixing the new helper name
  `effect`, which is accepted by OxCaml but reserved by upstream OCaml 5.4, to
  `effect_of_public`.

## Performance follow-up

The first focused comparison exposed deterministic per-operation allocations
from optional SPI arguments and log admission, plus wall measurements polluted
by host-wide drift. The hot seam was narrowed without exposing keys:

- `observability_named` now receives the already-captured kind and printer
  option as required arguments;
- hot behavioral calls carry targeted definition-site inline attributes;
- log admission no longer allocates an option block;
- metric construction remains behind the enabled gate.

Fifteen alternating before/after pairs (45 samples per side) put every affected
wall-time regression below 2%; the maximum is +1.936%. Allocation is equal or
lower on every changed row. Raw results and the method are in
`evidence/bench-pairs/`, `bench-parity.csv`, and `bench-parity.md`.

## Procedural deviation

An exclusion search was run from the repository root without excluding
`docs/research/`; ripgrep returned several matching lines from that forbidden
directory. No file there was opened separately, edited, or staged. Subsequent
searches explicitly excluded `docs/research/**`. This is recorded raw rather
than hidden.

## Red-team

All three required probes passed. A root-only Dune consumer cannot resolve the
SDK; Dune rejects a temporarily introduced real `eta <-> eta_observability`
cycle; and a root-only Eio consumer with a hand-written `Capabilities.tracer`
receives defect exception annotations from an internally named root effect.
Sources, commands, raw outputs, and verdicts are under `redteam/`.

## Verdict

Recommend **PROMOTE**. Dependency direction, exact gates, js_of_ocaml
single-package use, adversarial boundaries, migration completeness, and focused
runtime parity are proven by committed artifacts. The broad behavioral
`Spi.Expert` seam remains the weakest review target; no hold or kill trigger was
observed.
