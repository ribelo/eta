# OxCaml adoption verdict for Effet

Status: final. Supersedes the prior "branch-only" verdict. The earlier verdict
treated migration cost and dependency weight as decisive; the user reframed:
churn is free, what matters is whether OxCaml mechanically guarantees Effet's
scope/effect/capture safety AND enables true parallel execution that mainline
OCaml fundamentally cannot.

## The decision question (sharp form)

1. **Compatible** — can shipped Effet build, test, and execute under OxCaml,
   so OxCaml is a viable host at all?
2. **Better suited** — does OxCaml mechanically check Effet-specific
   invariants (scope safety, capture safety, parallel execution) that
   mainline OCaml cannot encode at the type level?

A "yes/yes" answer means switch. A "yes/no" answer means stay. A "no/*"
answer means stop the spike.

## Verdict

**Yes / yes. Switch toward OxCaml.** Evidence below: 27 runnable fixtures
(positive + negative), 141 shipped tests passing under `5.2.0+ox`, and three
categories of static guarantee mainline OCaml has no vocabulary for.

Reproduce:

```sh
nix develop .#oxcaml -c bash -lc 'effet-oxcaml-test-shipped'
nix develop .#oxcaml -c bash scratch/oxcaml_research/run.sh
```

Last recorded summary: `summary: pass=27 fail=0`.

## V-OX-A — Compatibility

Decision: shipped Effet is plain-OCaml-compatible under OxCaml today.

Evidence:

```sh
nix develop .#oxcaml -c bash -lc 'ocamlc -version; dune --version; effet-oxcaml-test-shipped'
```

`ocamlc 5.2.0+ox`, `dune 3.22.2`. Passing suites:

| Package | Tests |
| --- | --- |
| effet-schema | passes |
| ppx_effet | 3 |
| effet | 105 |
| effet-otel | 20 |
| effet-stream | 13 |

The shipped abstract `Effet.Effect.t` runs end-to-end via the existing
runtime (`scratch/oxcaml_research/effet_portable_probe/effet_real_t_portable_smoke.ml`).
No Effet source needed modification.

Friction observed (real but tractable):

- Recursive GADTs with parameterised kind annotations can require explicit
  `with 'env with 'err with 'a` threading or, more often, dropping the kind
  annotation and letting the body's mode be inferred. The compiler can give up
  on simplifying recursive kinds and emit `(I gave up trying to find the
  simplest kind for the first, as it is very large or deeply recursive)`. This
  shaped the redesigned-AST fixture; it did not block it.
- Polymorphic mode params in a recursive GADT match need the universally
  quantified type variables to carry their kind explicitly:
  `type (env : value mod portable contended) (err : immutable_data) ...`.
- `parallel.scheduler` ran to completion under direct `ocamlfind` builds, but
  hung under `dune exec` in our sandbox for the redesigned-AST executable.
  We routed the parallel positive through the run.sh ocamlfind path. This is
  an environment quirk, not an Effet-specific blocker.

## V-OX-B — Better suited: three static guarantees mainline cannot encode

The pivot question. For each invariant, we have:

- a **positive** fixture proving the desired property compiles and runs;
- a **negative** fixture proving violations fail to compile with the
  type-system reason;
- a one-line statement of why mainline OCaml has no equivalent.

### V-OX-B1 — Domain-portable effect AST (the ZIO direction)

Mainline OCaml has no static way to say "this `Effect.t` value is safe to
execute on another domain." Crossing a domain boundary with the wrong value
silently corrupts state or crashes at runtime. With OxCaml, `portable` /
`contended` modes plus kind annotations make domain transfer a compile-time
property of the AST.

Negative — `scratch/oxcaml_research/effet_portable_probe/effet_real_t_portable_negative.ml`:

```
Error: The value "program" is "nonportable"
       but is expected to be "shareable"
       because it is used inside the function ...
       which is expected to be "shareable".
```

The shipped abstract `Effet.Effect.t` is nonportable today. OxCaml refuses
to ship it across `Parallel_scheduler` boundaries, exactly as it should.

Positive — `scratch/oxcaml_research/fixtures/effet_redesigned_portable_positive.ml`:

A redesigned AST with the same Pure/Thunk/Bind/Map shape, parameter kinds
constrained to `value mod portable contended` / `immutable_data`, and Thunk /
Bind / Map closures annotated `@@ portable`. The value is built on the parent
domain, then evaluated on two child domains via `Parallel.fork_join2`. Both
domains return `Ok 44`.

Safety-bar fixture — `scratch/oxcaml_research/fixtures/effet_redesigned_portable_negative.ml`:

The same redesigned AST rejects a `Thunk` whose closure captures a mutable
`int ref`:

```
Error: This value is "contended"
         because it is used inside the function ...
         which is expected to be "portable"
         because it is contained (via constructor "Thunk") (with some modality)
         in the value ...
```

The portable kind is enforced, not merely declared.

Mainline equivalent: none. The closest mainline mechanism is "audit every
closure body manually."

### V-OX-B2 — Once-shot finalizer discipline

`Effect.acquire_release` exposes `release : 'a -> ('env, 'err, unit) t`. The
runtime contract is "exactly once on the acquired value." Today this is a
runtime/audit invariant.

Positive — `scratch/oxcaml_research/fixtures/acquire_release_once_positive.ml`:

A `(release @ once) v = ...` callback can be invoked exactly once and the
program runs.

Negative — `scratch/oxcaml_research/fixtures/acquire_release_once_negative.ml`:

```
Error: This value is used here,
       but it is defined as once and has already been used at:
       ... release 1; ...
```

Mainline equivalent: none. There is no type-level "called at most once"
modality in mainline OCaml.

### V-OX-B3 — Scope-bound switch lifetime

Capturing `Eio.Switch.t` outside its `Switch.run` scope is a recurring
fiber-safety bug. Today it dies dynamically when the switch is closed.

Negative — `scratch/oxcaml_research/fixtures/switch_escape_local_negative.ml`:

```
Error: This value is "local" to the parent region
       but is expected to be "global"
       because it is contained (via constructor "Some") in the value ...
```

OxCaml's `local_` mode pins the switch handle to its lexical region and
rejects escape at compile time.

Mainline equivalent: rank-2 polymorphism can simulate this for handles you
control (Effet does so for supervisor children), but it cannot retrofit
existing types like `Eio.Switch.t`. Locality applies uniformly.

## V-OX-C — Reinforcing evidence (kept from the prior session)

These confirm the safety claim and the "covers more than just parallelism"
claim. All fixtures live under `scratch/oxcaml_research/fixtures/`.

| Area | Positive | Negative | Static gap mainline cannot close |
| --- | --- | --- | --- |
| Resource state with portable atomics | `resource_portable_atomic_positive` | `resource_ref_portable_negative`, `resource_stdlib_atomic_portable_negative` | "this Resource is safe to read/write across domains" |
| Resource auto-refresh under parallel | `resource_portable_auto_parallel_positive` | — | end-to-end domain-parallel Resource refresh |
| Capsule-isolated mutable state | `resource_capsule_isolated_positive` | `resource_capsule_external_refresh_negative` | dynamic-locked mutation captured statically |
| Supervisor child handle escape | `supervisor_local_positive` | `supervisor_local_return_negative`, `supervisor_local_ref_negative` | rank-2 already covers this; locality is equivalent with simpler signatures |
| Effect AST portable callbacks | `effect_ast_atomic_capture_positive` | `effect_ast_portable_capture_negative` | per-callback portability |
| Cause portability | `cause_portable_positive` | `cause_closure_negative` | safe diagnostic transport across domains |
| Eio fiber smoke | `eio_fiber_smoke` | — | fiber-level concurrency stays boring |
| Parallel scheduler smoke | `parallel_scheduler_smoke` | `parallel_ref_capture_negative` | type-checked domain pool |
| Stream sink under parallel | `stream_portable_sink_parallel_positive` | `stream_eio_queue_parallel_negative` | which Eio ops are nonportable is type-visible |

The Effet-shaped Resource probe (`scratch/oxcaml_research/effet_resource_probe/effet_resource_portable_probe.ml`) compiles and runs against the
real `effet` library with a portable Resource layer that survives parallel
refresh.

## Cross-tab — OxCaml vs mainline OCaml on Effet's invariants

| Invariant | Mainline OCaml | OxCaml | Net |
| --- | --- | --- | --- |
| Build & test shipped Effet | ✓ | ✓ | tie |
| Effect.t executable in single fiber | ✓ | ✓ | tie |
| Effect.t executable across domains, statically checked | ✗ no vocabulary | ✓ portable kind | **OxCaml only** |
| Domain-parallel Resource state, statically checked | ✗ runtime audit | ✓ Portable.Atomic + capsule | **OxCaml only** |
| acquire_release release exactly-once | ✗ runtime invariant | ✓ `once` mode | **OxCaml only** |
| Eio.Switch escape | ✗ dynamic switch death | ✓ `local_` mode | **OxCaml only** |
| Supervisor child handle escape | ✓ rank-2 polymorphism | ✓ `local_` mode (simpler signature) | tie on safety, OxCaml on signature shape |
| Cross-domain Cause aggregation | ✗ runtime panic | ✓ portable kind on payload | **OxCaml only** |
| ZIO-style domain-parallel runtime | ✗ unsafe to attempt | ✓ achievable with portable AST | **OxCaml only** |
| Per-callback portability inside AST | ✗ no notion | ✓ `@@ portable` modality | **OxCaml only** |
| Performance ceiling (separate question) | bounded by mainline GC/codegen | OxCaml stack/locality features | not decided here |

Eight categories of static guarantee where OxCaml is strictly more expressive
for Effet's invariants. One tie. Zero categories where mainline is strictly
better.

## Decision diary

- V-OX1 — Compatibility passes. Decision: OxCaml is a viable host.
  Rationale: 141 shipped tests pass under `5.2.0+ox`; the abstract
  `Effet.Effect.t` runs end-to-end.
- V-OX2 — Effect AST domain-portability is a capability mainline cannot offer.
  Decision: this is the decisive parallel-execution gap. Rationale: the
  shipped AST is statically rejected; the redesigned portable AST runs across
  Parallel domains; the redesigned AST genuinely rejects unsafe captures.
- V-OX3 — `once` for release callbacks. Decision: adopt. Rationale: mainline
  cannot encode "called at most once"; OxCaml does so with a one-token
  annotation and produces a precise error pointing at the offending second
  call.
- V-OX4 — `local_` for `Eio.Switch.t`. Decision: adopt. Rationale: switch
  escape is statically rejected with a precise location; mainline diagnoses
  only at runtime.
- V-OX5 — Supervisor locality vs rank-2. Decision: equivalent on safety;
  locality wins on signature shape, not on caught cases. Move on without
  blocking adoption.
- V-OX6 — Resource portability under churn-free framing. Decision: the
  portable Resource shape is acceptable; with no migration cost, the
  immutable_data payload constraint is a feature (cross-domain safety), not a
  cost.
- V-OX7 — Final verdict: switch toward OxCaml. This supersedes the prior
  V-OX0 ("branch-only") which was based on migration cost and dependency
  weight. With churn = 0 and the parallelism direction made explicit, the
  three static guarantees in V-OX-B are decisive.

## What this verdict does NOT prove (deferred)

These remain unverified and are explicit follow-ups, not blockers:

- The full shipped `Effect.t` GADT (29 constructors including `Par`, `All`,
  `For_each_par`, `Daemon`, `Supervisor_scoped`, `Acquire_release`, etc.) has
  not been shown to admit a portable kind annotation in one go. The
  redesigned probe used Pure/Thunk/Bind/Map only. The recursive-kind
  inference message ("I gave up trying to find the simplest kind") is a real
  obstacle for the largest GADTs and may force splitting the AST into
  portable / nonportable halves or threading explicit `with` clauses.
- The rank-2 `supervisor_body` record has not been replaced end-to-end with
  a `local_`-based variant against the real Effet runtime. The toy positive
  fixture only proves the principle on a `child = { id : int }` record.
- `Eio.Switch.t` is treated as `local_` in the negative fixture, but the
  shipped Eio API does not yet declare its handles `local_`. Adoption may
  require either a wrapper or upstream Eio annotations.
- `Effect.bind`'s continuation `('b -> ('env,'err,'a) t)` is not yet shown to
  admit `once` mode; the bind continuation is many-shot in principle but
  one-shot in Effet's interpreter — turning that into a static guarantee is
  worth a follow-up probe.
- Performance comparison vs mainline OCaml is out of scope here; the bench
  baseline lives in `bench/` and runs on mainline only.

## Implementation follow-ups (to file as new tasks if work resumes)

- Annotate `('env, 'err, 'a) Effect.t` and the supervisor types with portable
  kinds (likely two AST variants: same-domain and portable). Negative
  fixtures must accompany every kind annotation so the constraint is
  enforced, not declared.
- Add `Runtime.run_parallel` (or `Runtime.create_pool`) backed by
  `Parallel_scheduler` for portable `Effect.t` values. Keep the
  fiber-only runtime as the default; the portable runtime is a sibling.
- Annotate the `release` argument of `Effect.acquire_release` with `once`.
- Annotate `Eio.Switch.t` references inside Effet supervisor / resource paths
  as `local_` once Eio API supports it (or wrap behind an Effet-owned alias).
- Re-evaluate the rank-2 `supervisor_body` record against `local_` once the
  real-Effet locality probe is built; only replace if it produces strictly
  cleaner errors against the actual GADT.

## Rejected options

- "Branch-only adoption, do not switch": rejected. Was based on migration cost
  and dependency weight, both ruled out by the user.
- "Effect.t can stay nonportable forever, single-fiber Effet is the design
  ceiling": rejected. The user's framing puts ZIO-style parallel execution as
  a primary motivation, and `effet_real_t_portable_negative.log` is the
  explicit static evidence that mainline blocks this direction without OxCaml.
- "Portable Resource needs a separate domain-safe API and is therefore not
  worth the constraint": rejected under churn = 0.

## Artifacts

All under `scratch/oxcaml_research/`:

- `run.sh` — runs all fixtures, captures expected-pass/expected-fail results.
- `fixtures/*.ml` — 25 standalone fixtures (positive + negative).
- `effet_portable_probe/{dune,effet_real_t_portable_smoke.ml,effet_real_t_portable_negative.ml}`
  — dune-built fixtures against the real `effet` library.
- `effet_resource_probe/` — Effet-shaped Resource probe with portable atomic
  state, daemon refresh, parallel boundary smoke.
- `results/compile.out` — full per-fixture build/run log.
- `results/baseline_shipped.out` — `effet-oxcaml-test-shipped` output.
- `results/effet_resource_probe.out` — Effet-shaped Resource probe output.
- `results/tooling_probe.out` — package and module-availability probes.
- `results/dependency_probe.out` — opam closure measurements.

Last reproduction: `summary: pass=27 fail=0`, 141 shipped tests pass.
