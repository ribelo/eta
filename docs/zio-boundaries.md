# ZIO / Effect Boundaries

Eta borrows useful ideas from TypeScript Effect and Scala ZIO, but it is an
OCaml library with its own public contracts. Missing ZIO or Effect APIs are not
bugs by themselves. Add a compatible surface only when it improves Eta's OCaml
contract, not because an upstream API exists.

## Environment and Layers

Eta's core type is:

```ocaml
('a, 'err) Effect.t
```

There is no environment parameter, `Layer`, service `Tag`, or dynamic
`provide` operation. Applications pass dependencies as ordinary OCaml values:
records, modules, closures, and handles. Runtime services such as clock,
tracing, logging, metrics, and random are interpreter configuration rather
than an application dependency row. Native worker capabilities such as
`Eta_blocking.Pool.t` and `Eta_par.Island.Pool.t` live in optional packages
and are passed explicitly where code needs them.

See [Services Without Layer](services.md) for the project convention.

### Why, with evidence

This is a settled decision, resting on four independent evidence lines
(full record: `.scratch/research/envless-verdict-2026-07-26.md`):

1. **Portability (decisive).** Object-row environments are not portable
   across OxCaml domain boundaries ("object kind was value mod global
   many non_float, not value mod portable contended" — V-Recovery-R2).
   The env parameter shipped after V-R10 was removed for exactly this
   reason (`7417b03b`, 2026-05-22). Restoring it would kill the
   islands/portable direction or force a second effect type.
2. **Every R component was survival-tested and fell.** `provide` was
   deleted after three with/without fixture pairs behaved identically
   (and were shorter without it — V-RPv5); restricted `Layer` merge was
   "not materially better than ordinary OCaml" (V-RLv5); at 20 modules /
   30 capabilities, missing-capability row errors are 2295 bytes vs. 689
   for ordinary arguments, hovers are dense rows, and every reusable
   env-row value needs a thunk.
3. **The value restriction is structural, not stylistic.** Any
   env-reading constructor makes the env parameter non-covariant, so
   reusable effect values get weak type variables (mandatory
   eta-expansion), layer values cannot cross compilation units, and
   memoisation-by-reference-identity dies.
4. **Cross-library object-row keys are unsound.** Global structural
   names: silent same-shape collisions, renames are breaking type
   changes, and the adapter remedies recreate ordinary functor-based DI
   at extra cost.

The one genuine win of an env channel — a deep leaf gaining a dependency
touches 1 file instead of ~4 — is real but bounded;
[services.md](services.md) documents the composite-record recipe that
absorbs it locally. The in-repo race (V-DX-E16, `Reader` vs.
value-passing on one real service) went 4-0-1 for value-passing, with
the boundary condition (deep graphs, ~6+ deps across layers) recorded.
Reopen conditions are measurable and live in the verdict document §7;
until one fires, this question is closed.

## Errors and Defects

Typed failures are values produced by `Effect.fail`, `Effect.from_result`, or
helpers such as `Eta_blocking.run_result`. Ordinary OCaml exceptions raised
inside `Effect.sync`, `Eta_blocking.run`, or a blocking callback are unchecked
defects and surface as `Cause.Die`.

`Effect.bind_error` handles typed failures only. `Effect.catch_some` selectively
handles the first typed failure while preserving the original cause on
non-match. Neither handles defects, interruption, or finalizer diagnostics. Eta
intentionally does not expose a ZIO-style `catchAllCause`, `sandbox`,
`unsandbox`, or `attempt` that turns arbitrary exceptions into typed failures.
For expected leaf errors, return `result` and lift it. For every-branch
concurrent outcomes, use `Effect.all_settled` or explicit result values.

## Fiber-Local State and Promises

Eta uses Eio fiber keys internally for runtime context, observability context,
and diagnostics. It does not expose a ZIO `FiberRef` equivalent with
fork-inherit and join-merge semantics. Prefer lexical arguments and explicit
state. Add ambient fiber-local user state only if Eta owns a clear invariant
that cannot be expressed with ordinary OCaml values.

Runtime services meet that rule. `Effect.with_clock`, `with_random`,
`with_logger`, and `with_tracer` temporarily replace an Eta-owned interpreter
service for one dynamic subtree; they do not add application dependencies or an
environment parameter. The innermost binding wins, children inherit at fork,
there is no join-merge, and concurrent siblings remain isolated:

```ocaml
Effect.par
  (Effect.with_clock test_clock left)
  (Effect.with_clock test_clock right)
```

Put the override around both branches when both need it; putting it inside only
`left` cannot affect `right`. Leaves select the active service when called. An
already sleeping fiber or open span keeps the service with which that operation
started, and a runtime-owned daemon keeps the binding it inherited at fork even
after the lexical override returns.

Log interception is another fiber-local stage, not a sink replacement. The
fixed pipeline is scoped minimum-level filter, scoped then per-call attributes,
outermost-to-innermost `Effect.intercept_log` transforms, and finally the
currently bound logger. `Keep` passes the record unchanged, `Replace record`
substitutes it, and `Drop` stops the remaining transforms and drops it.
Consequently both
`Effect.intercept_log scrub (Effect.with_logger sink body)` and
`Effect.with_logger sink (Effect.intercept_log scrub body)` scrub records before
`sink`; moving the logger override does not bypass interception. Metric
interception follows the same nesting and drop rules after a metric point is
built and before the current meter.

Eta also does not wrap `Eio.Promise`, `Eio.Mutex`, or `Eio.Condition` as
generic effect data types. Use them directly for local coordination. Wrap Eio
only when Eta owns typed failure preservation, cancellation cleanup, scoped
lifecycle, close fences, backpressure ownership, portability fences, or runtime
observability.

## Concurrency

Eta does not expose escaping ZIO-style fiber handles as the default concurrency
model. Public child work is lexical:

- `Effect.par`, `Effect.all`, `Effect.race`, and `Effect.map_par` for
  concurrent effect composition.
- `Supervisor.scoped` when a parent needs child handles inside a nursery.
- `Effect.with_background` when required background work should live only while
  a body runs and fail that body if it dies.
- `Effect.with_supervised_background` for the same lifetime without fail-fast
  child-to-body propagation.

Runtime-owned daemon work stays internal to modules that own that lifecycle.
There is no public `forkDaemon` API for application code.

## Data Primitives

Eta has small, focused primitives rather than ZIO-compatible data structures:

- `Mutable_ref` is a named `Atomic.t` wrapper with CAS-style operations, not a
  ZIO `Ref` or `Ref.Synchronized`.
- `Queue` is a cross-domain producer/consumer queue with close/error fences.
- `Channel` is a same-domain bounded backpressure channel.
- `Pubsub` is a same-domain scoped broadcast hub with explicit overflow
  policy.
- `Pool` is a same-domain bounded resource pool for ordinary handles, not a
  ZIO `ZPool` clone.
- `Semaphore` is a cancellation-safe counting semaphore.

Eta core has no STM, Chunk, ZManaged, ZSink, or ZChannel compatibility layer.
`eta_stream` is an optional Eta stream package, not a ZIO stream clone.

## Resource, Three Ways

`Resource` names three different ideas in the reference libraries:

1. **Cats Effect `Resource` / ZIO 1 `ZManaged`: an acquire/release
   descriptor.** It reifies a composable resource blueprint with acquisition,
   use, and release. The ZIO 1 implementation lives under
   `.reference/zio/managed/`; the ZIO 2 migration guide explicitly places it in
   the same lineage as Cats Effect `Resource`
   (`.reference/zio/docs/guides/migrate/migration-guide.md`, “Scopes”).
2. **Effect-TS `Resource`: a refreshable cached value.** It stores the latest
   acquisition result and exposes `manual`, `auto`, `get`, and `refresh`.
   Eta's former `Eta.Resource` was a faithful port of this refreshable-cache
   shape, not the Cats/ZManaged shape. Evidence:
   `.reference/effect-smol/packages/effect/src/Resource.ts`.
3. **ZIO 2 resource primitives: acquisition directly in `ZIO`, bounded by a
   first-class `Scope`.** ZIO 2 deleted `ZManaged`. Its migration guide records
   the reasons: users had to learn when to use `ZIO` versus `ZManaged`; every
   `ZIO` method had to be reimplemented on `ZManaged` in a more complex form;
   and the extra layer was slower. The replacement is `Scope` plus
   `ZIO.acquireRelease`.

Eta already has the third architecture. The mapping is:

| ZIO 2 | Eta |
| --- | --- |
| `ZIO.acquireRelease` | `Effect.acquire_release` |
| `acquireReleaseWith(...).use(...)` | `Effect.with_resource` |
| `acquireReleaseExitWith` | `Effect.with_resource_exit` |
| `ZIO.scoped` | `Effect.with_scope` |
| Parallel acquisition into one scope | `Effect.acquire_all_par` |

The current declarations from `lib/eta/effect.mli`, verbatim, are:

```ocaml
val acquire_release :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'release_err) t) ->
  ('a, 'err) t

val with_resource :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'release_err) t) ->
  ('a -> ('b, 'err) t) ->
  ('b, 'err) t

val with_resource_exit :
  acquire:('a, 'err) t ->
  release:('a -> ('b, 'err) Exit.t -> (unit, 'release_err) t) ->
  ('a -> ('b, 'err) t) ->
  ('b, 'err) t

val with_scope : ('a, 'err) t -> ('a, 'err) t

val acquire_all_par :
  ?max_concurrent:int ->
  acquire:('c -> ('a, 'err) t) ->
  release:('a -> (unit, 'r) t) ->
  'c list -> ('a list, 'err) t
```

Eta's scope is runtime-owned through the fiber frame; under the no-R boundary
above, it does not need a type-level environment. Eta will not grow a reified
`Resource.t` or `ZManaged` descriptor. `Effect.t` is already the blueprint
language, so adding a second descriptor language would recreate the duplication
ZIO 2 removed.

The rename to `Eta_cache.Refreshable` therefore stands even though Effect-TS
uses `Resource` for the same refreshable shape. Eta's API and documentation
already use “resource” throughout for acquire/release lifetimes:
`Effect.acquire_release`, `Effect.with_resource`, scopes, pools, and finalizers.
`Refreshable` removes that internal collision and says what the cached value
does.

### Open question: Refreshable generation scoping

Effect-TS builds its `Resource` on `ScopedRef`. A successful `refresh` replaces
the generation and closes the previous generation's scope, releasing resources
owned by the replaced value
(`.reference/effect-smol/packages/effect/src/Resource.ts`).
`Eta_cache.Refreshable` currently swaps a plain value. If a loaded generation
owns a file watcher, connection, or similar resource, replacing it does not
release that resource and can leak it.

This is a watch item, not an API action. Its evidence gate fires only when a
real Eta use case loads generations that hold resources. If it fires, design
Effect-TS `ScopedRef`-style close-previous-on-replace semantics; until then the
plain-value boundary remains explicit.

## Schedules

`Schedule.t` is a pure recurrence-policy description used by retry, repeat,
and resource refresh. It produces delays; it is not ZIO's input/output schedule
algebra. Eta intentionally keeps only the schedule forms it currently drives:
`recurs`, `forever`, `spaced`, `fixed`, `exponential`, `linear`,
`both`, `either`, `and_then`, `jittered`, and `named`.

Cron-like schedules, interval algebra, schedule drivers with input/output state,
and effectful schedule combinators should be added only when an Eta workflow
needs them.

## Naming, Tracing, and Style

Eta uses OCaml naming and types: snake_case functions, module-owned types,
polymorphic variants for typed errors, and ordinary OCaml backtraces for defect
diagnostics. There is no implicit ZIO `Trace` parameter. Tracing, logging, and
metrics are explicit runtime capabilities plus `Effect.named`,
`Effect.annotate`, and related observability combinators.
