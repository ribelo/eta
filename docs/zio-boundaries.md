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

## Errors and Defects

Typed failures are values produced by `Effect.fail`, `Effect.from_result`, or
helpers such as `Eta_blocking.run_result`. Ordinary OCaml exceptions raised
inside `Effect.sync`, `Eta_blocking.run`, or a blocking callback are unchecked
defects and surface as `Cause.Die`.

`Effect.catch` handles typed failures only. `Effect.catch_some` selectively
handles the first typed failure while preserving the original cause on
non-match. Neither catches defects, interruption, or finalizer diagnostics. Eta
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

Eta also does not wrap `Eio.Promise`, `Eio.Mutex`, or `Eio.Condition` as
generic effect data types. Use them directly for local coordination. Wrap Eio
only when Eta owns typed failure preservation, cancellation cleanup, scoped
lifecycle, close fences, backpressure ownership, portability fences, or runtime
observability.

## Concurrency

Eta does not expose escaping ZIO-style fiber handles as the default concurrency
model. Public child work is lexical:

- `Effect.par`, `Effect.all`, `Effect.race`, and `Effect.for_each_par` for
  concurrent effect composition.
- `Supervisor.scoped` when a parent needs child handles inside a nursery.
- `Effect.with_background` when background work should live only while a body
  runs.

Runtime-owned daemon work stays internal to modules that own that lifecycle.
There is no public `forkDaemon` API for application code.

## Data Primitives

Eta has small, focused primitives rather than ZIO-compatible data structures:

- `Mutable_ref` is a named `Atomic.t` wrapper with CAS-style operations, not a
  ZIO `Ref` or `Ref.Synchronized`.
- `Queue` is a same-domain unbounded FIFO with close/error fences.
- `Channel` is a same-domain bounded backpressure channel.
- `Pubsub` is a same-domain scoped broadcast hub with explicit overflow
  policy.
- `Pool` is a same-domain bounded resource pool for ordinary handles, not a
  ZIO `ZPool` clone.
- `Semaphore` is a cancellation-safe counting semaphore.

Eta core has no STM, Chunk, ZManaged, ZSink, or ZChannel compatibility layer.
`eta_stream` is an optional Eta stream package, not a ZIO stream clone.

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
