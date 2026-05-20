# Effet

Effet is an OCaml effect library shaped by TypeScript Effect and Scala ZIO.
It keeps the useful axes: environment requirements, typed failures, and
success values.

It is not an Elm Architecture framework. There is no message loop, inbox,
subscription reconciler, or state container. Applications own their
state; Effet owns effect description and interpretation.

## Core Type

```ocaml
('env, 'err, 'a) Effect.t
```

- `'env` is the requirement channel. Structural object types work well for
  capabilities.
- `'err` is the typed failure channel. Polymorphic variants give precise,
  inferred error rows.
- `'a` is the success value.

## Example

```ocaml
open Effet

let program =
  Effect.pure 1
  |> Effect.map (fun n -> n + 1)
  |> Effect.bind (fun n ->
         if n < 3 then Effect.fail `Too_small else Effect.pure n)
  |> Effect.catch (fun `Too_small -> Effect.pure 3)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  match Runtime.run rt program with
  | Exit.Ok n -> Format.printf "%d@." n
  | Exit.Error (Cause.Fail `Too_small) -> assert false
  | Exit.Error _ -> assert false
```

## Features

| Module | Purpose |
| --- | --- |
| `Effect` | Abstract description for pure values, typed failure, thunk leaves, bind/map/tap, catch, timeout, race, repeat, retry, uninterruptible regions, scopes. |
| `Supervisor` | Scope-bound nursery for child effects with observable failures, typed await, and cancellation. |
| `Cause` | Slim failure tree: typed failure, unchecked exception, interruption, and parallel failures. |
| `Exit` | Runtime boundary result: success or failure cause. |
| `Runtime` | Eio-backed interpreter for `Effect.t`. |
| `Duration` | Millisecond-precision durations. |
| `Schedule` | Pure recurrence descriptions for repeat and retry. |
| `Resource` | Cached effectful resources with explicit refresh and refresh-failure inspection. |
| `Capabilities` | Small object-type traits for capability-oriented environments. |
| `Trace_context` | W3C traceparent/tracestate/baggage extract and inject helpers for distributed tracing. |

## PPX Helpers

The optional `ppx_effet` package provides small syntax helpers. They expand to
ordinary `Effect` and object code; they do not infer services, build dependency
graphs, or add runtime semantics.

```ocaml
let load_user id =
  [%effet.fn
    (Effect.thunk "db.query" (fun env -> env#db#user id))]
```

It expands to:

```ocaml
Effect.fn __POS__ __FUNCTION__
  (Effect.thunk "db.query" (fun env -> env#db#user id))
```

Leaf effects can bind an explicit capability list so the body cannot read
`env` directly:

```ocaml
let current_user () =
  [%effet.thunk "auth.current_user" (auth : Auth.t)
    (Auth.current_user auth)]
```

This expands to `Effect.fn __POS__ __FUNCTION__ (Effect.thunk ...)`, with a
generated env argument and local typed `auth` binding. Use the explicit `()` for
exported or reusable env-row effects; it avoids OCaml value-restriction weak
variables.

Runtime-boundary env objects can be generated with local type annotations:

```ocaml
let env =
  [%effet.env { auth = (auth : Auth.t); clock = (clock : Capabilities.clock) }]
```

Use it by adding `ppx_effet` to your test or executable preprocessors:

```lisp
(preprocess
 (pps ppx_effet))
```

The PPX is deliberately syntactic. It does not provide `Layer`, `Context`,
`Tag`, implicit service lookup, inferred env construction, or argument/env-row
conversion.

## Resource Scopes

`Effect.acquire_release` registers finalizers with the surrounding
`Effect.scoped`. Finalizers run on success, typed failure, and cancellation.

```ocaml
let with_db k =
  let acquire = Effect.thunk "db.open" (fun env -> env#db#open_) in
  let release handle =
    Effect.thunk "db.close" (fun env -> env#db#close handle)
  in
  Effect.scoped
    (Effect.acquire_release ~acquire ~release |> Effect.bind k)
```

## Services

Effet does not ship `Layer.t`, `Tag`, `Context`, or `Effect.provide`.
Build service graphs with ordinary OCaml functions and keep resource lifetime
inside `Effect.scoped`.

See [Services Without Layer](docs/services.md) for the project convention and
failure modes.

## Supervised Concurrency

Use `Supervisor.scoped` when a parent needs handles for child effects without
letting those handles escape their owning scope.

~~~ocaml
let supervised =
  Supervisor.scoped {
    run =
      fun sup ->
        let open Supervisor.Scope in
        let* child = start sup (lift (Effect.pure 42)) in
        await child
  }
~~~

Child failures are recorded on the supervisor and do not fail the parent unless
you `await` the child or explicitly check a failure threshold.

~~~ocaml
let observed =
  Supervisor.scoped {
    run =
      fun sup ->
        let open Supervisor.Scope in
        let* _child = start sup (fail `Refresh_failed) in
        let* () = yield in
        failures sup
  }
~~~

`Supervisor.scoped` is the public way to start child work. Runtime-owned
background work stays internal to modules that own that lifecycle. For
long-lived cached resources, `Resource.auto` keeps the existing returned
resource shape and records refresh failures through `Resource.failures`.

## Eio Concurrency Data

Use Eio data primitives directly for local coordination:

| Need | Use |
| --- | --- |
| Bounded producer/consumer queue | `Eio.Stream` |
| One-shot signal or shared result | `Eio.Promise` |
| Countdown or wait-for-condition | `Eio.Condition` with `Eio.Mutex` |
| Broadcast with drop/backpressure policy | Application-owned queues or `effet-stream` when it is stream-shaped |

Effet does not ship `Effect.Queue`, `Effect.Deferred`, `Effect.PubSub`, or
`Effect.Latch`. The lab found that adding close/fail state, slow-consumer
policy, and nonblocking shutdown makes these wrappers policy-owning
abstractions, not thin aliases.

Wrap Eio operations in `Effect.thunk` at the leaf when they need typed failure
conversion, env-row requirements, or tracing names. If a protocol is reusable
and owns lifecycle semantics, prefer a focused module such as `Resource` or
`effet-stream` rather than a generic concurrency-data wrapper.

## Trace Propagation

Tracing is configured on the runtime, not through the env row:

```ocaml
let rt =
  Runtime.create ~sw ~clock ~tracer:(Effet_otel.tracer exporter) ~env:() ()
```

Typed failures render as `"<typed failure>"` in span status and exception events
unless a named effect supplies a typed renderer:

```ocaml
let save =
  Effect.named
    ~error_renderer:(function `Db code -> "db:" ^ string_of_int code)
    "db.save"
    (Effect.fail (`Db 42))
```

Use `Effect.with_error_renderer` when several named spans share the same error
channel. The renderer is scoped to that effect subtree; caught inner errors keep
the conservative default unless they provide their own renderer.

At service boundaries, extract W3C headers and install the context around the
request effect:

```ocaml
let handle headers =
  let body = Effect.named_kind ~kind:Capabilities.Server "http.request" work in
  match Trace_context.extract headers with
  | None -> body
  | Some ctx -> Effect.with_context ctx body
```

Inside the request, outbound clients can read and inject the current context:

```ocaml
let outbound_headers =
  Effect.current_context
  |> Effect.map (function
       | None -> []
       | Some ctx -> Trace_context.inject ctx)
```

`Effect.with_context` preserves the W3C sampled flag, `tracestate`, and
`baggage`. `Effect.with_external_parent` remains as a compatibility helper
when only a trace ID and parent span ID are available.

## Development

Use the Nix shell when available:

```sh
nix develop -c dune runtest --force
```

Performance and compile-time history lives in the opt-in bench suite:

```sh
nix develop -c bash bench/run.sh --quick
```

See [bench/README.md](bench/README.md) for the JSON format, comparison tool,
and bisect workflow. `dune runtest` does not run benchmarks; `dune build
@bench` runs the runtime benchmark executables only.

Without Nix:

```sh
opam install . --deps-only --with-test
dune runtest --force
```

The research journal is intentionally ignored by Git. It records the full
project history and local design reasoning, but it is not part of the
published package.
