# Eta

Eta is an OCaml effect library shaped by TypeScript Effect and Scala ZIO.
It keeps the useful axes: typed failures and success values.

It is not an Elm Architecture framework. There is no message loop, inbox,
subscription reconciler, or state container. Applications own their
state; Eta owns effect description and interpretation.

## Core Type

```ocaml
('a, 'err) Effect.t
```

- `'a` is the success value.
- `'err` is the typed failure channel. Polymorphic variants give precise,
  inferred error rows.

Dependencies are ordinary OCaml values. Pass records, modules, closures, or
handles to functions that build effects; Eta does not provide a ZIO-style
environment or layer graph.

## Example

```ocaml
open Eta

let program =
  let open Syntax in
  let* n = Effect.pure 1 |> Effect.map (fun n -> n + 1) in
  (if n < 3 then Effect.fail `Too_small else Effect.pure n)
  |> Effect.catch (fun `Too_small -> Effect.pure 3)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  match Runtime.run rt program with
  | Exit.Ok n -> Format.printf "%d@." n
  | Exit.Error (Cause.Fail `Too_small) -> assert false
  | Exit.Error _ -> assert false
```

## Features

| Module | Purpose |
| --- | --- |
| `Effect` | Abstract description for pure values, typed failure, sync leaves, bind/map/tap, catch, timeout, race, repeat, retry, uninterruptible regions, scopes. |
| `Syntax` | Binding operators for `Effect.t`: `let*`, `let+`, `and*`, and `and+`. |
| `Supervisor` | Scope-bound nursery for child effects with observable failures, typed await, and cancellation. |
| `Cause` | Slim failure tree: typed failure, unchecked exception, interruption, and parallel failures. |
| `Exit` | Runtime boundary result: success or failure cause. |
| `Runtime` | Eio-backed interpreter for `Effect.t`. |
| `Duration` | Millisecond-precision durations. |
| `Schedule` | Pure recurrence descriptions for repeat and retry. |
| `Resource` | Cached effectful resources with explicit refresh and refresh-failure inspection. |
| `Capabilities` | Small object-type traits for runtime services and explicit dependencies. |
| `Redacted` | Opaque wrapper for sensitive values that redacts string and JSON output. |
| `Trace_context` | W3C traceparent/tracestate/baggage extract and inject helpers for distributed tracing. |

## Portable Islands

`Effect.island` is the portable twin of `Effect.sync`: it runs one
compiler-checked portable callback through a runtime-owned island pool.

```ocaml
let (square @ portable) n = n * n

let program =
  Effect.island ~name:"square" square 7
```

Finite batches use `Effect.Island.map`, `map_result`, or `all_settled`.
Inputs, outputs, and callback error values must be `immutable_data`; the
callback itself is `@ portable`, so captures such as refs, Eio streams,
runtimes, loggers, or raw causes are rejected by the compiler.

```ocaml
let pool = Effect.Island.Pool.create ~domains:2 ()

let rt =
  Runtime.create ~sw ~clock ~island_pool:pool ()
```

There is no silent fallback. If island work reaches `Runtime.run` without a
runtime pool or per-run `~island_pool` override, the effect dies. Island v1 is
callback-based only: no timeout, cancellation, preemption, online queue, public
`Effect.Portable.t`, or portable Resource/Supervisor/Stream/OTel surface is
implied.

For structured CPU parallelism over arrays or recursive fork/join algorithms,
use `Eta.Par` from the core `eta` package (`Eta.Par.run`, `Eta.Par.join`,
`Eta.Par.par_map`, `Eta.Par.Iter`). See [Concurrency primitives in Eta](docs/concurrency-guide.md) for
the decision flow between `Effect.sync`, Islands, `Par`, and Blocking.

## PPX Helpers

The optional `ppx_eta` package provides small syntax helpers. They expand to
ordinary `Effect` and object code; they do not infer services, build dependency
graphs, or add runtime semantics.

```ocaml
let load_user id =
  [%eta.fn
    (Effect.named "db.query" (Effect.sync (fun () -> Db.user id)))]
```

It expands to:

```ocaml
Effect.fn __POS__ __FUNCTION__
  (Effect.named "db.query" (Effect.sync (fun () -> Db.user id)))
```

Leaf effects can bind an explicit capture list so the body cannot read an
ambient `env`:

```ocaml
let current_user auth =
  [%eta.sync "auth.current_user" (auth : Auth.t)
    (Auth.current_user auth)]
```

This expands to `Effect.fn __POS__ __FUNCTION__ (Effect.named ... (Effect.sync ...))`, with a
zero-argument callback and a local typed `auth` binding.

Use it by adding `ppx_eta` to your test or executable preprocessors:

```lisp
(preprocess
 (pps ppx_eta))
```

For Eta SQL (`eta_sql`), the same PPX also provides optional table declaration sugar:

```ocaml
[%%eta.sql.table
type users = {
  id : int [@primary_key];
  name : string [@not_null];
  active : bool [@not_null];
}]
```

It expands to the ordinary `Sql.Table.Make` module shape, typed columns, a
`users_row` record, `Users.all`, and `Users.schema`. The input declaration is
consumed by the PPX; application code refers to `users_row` for all-column
result records. Partial projections still use the ordinary tuple-returning
builder helpers.

The PPX is deliberately syntactic. It does not provide `Layer`, `Context`,
`Tag`, implicit service lookup, inferred dependency construction, or argument
conversion.

## Resource Scopes

`Effect.acquire_release` registers finalizers with the surrounding
`Effect.scoped`. Finalizers run on success, typed failure, and cancellation.

```ocaml
let with_db k =
  let acquire = Effect.named "db.open" (Effect.sync (fun () -> Db.open_)) in
  let release handle =
    Effect.named "db.close" (Effect.sync (fun () -> Db.close handle))
  in
  Effect.scoped
    (Effect.acquire_release ~acquire ~release |> Effect.bind k)
```

For one-shot cleanup around a single effect, use `Effect.finally`:

```ocaml
let write_then_flush writer bytes =
  Writer.write writer bytes
  |> Effect.finally (Effect.sync (fun () -> Writer.flush writer))
```

The cleanup runs after success, typed failure, unchecked defect, or
cancellation. If both the body and cleanup fail, Eta reports the cleanup failure
as suppressed under the body failure, using the same cause shape as
`acquire_release`.

## Services

Eta does not ship `Layer.t`, `Tag`, `Context`, or `Effect.provide`.
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

For background work that exists only while a body runs, prefer
`Effect.with_background`:

```ocaml
let with_stream_reader flow use =
  Effect.with_background
    ~name:"stream.reader"
    (Effect.sync (fun () -> read_loop flow))
    (fun () -> use flow)
```

This is the structured shape for daemon-like application work without using a
runtime-owned daemon: accept loops scoped to a server lifetime, stream readers
scoped to a handle, heartbeat/ticker loops scoped to a session, and resource
readers scoped by `acquire_release`. The background child is cancelled when the
body returns or fails. Its failures are not awaited by `with_background`; report
them through an owned queue, promise, log, or use `Supervisor.scoped` when the
body must observe child failure.

## Eio Concurrency Data

Use Eio data primitives directly for local coordination:

| Need | Use |
| --- | --- |
| Bounded producer/consumer queue | `Eio.Stream` |
| One-shot signal or shared result | `Eio.Promise` |
| Countdown or wait-for-condition | `Eio.Condition` with `Eio.Mutex` |
| Eta-owned FIFO with close/error fences | `Eta.Queue` or `Eta.Channel` |
| Scoped broadcast with drop/backpressure policy | `Eta.Pubsub` |

`Pubsub` uses a shared hub buffer with scoped subscriptions. Published messages
are admitted once at the hub, then retained until current subscribers receive
them or unsubscribe. The overflow policy is explicit:

```ocaml
let hub = Pubsub.create ~overflow:(Pubsub.Backpressure { capacity = 64 }) ()

let use_events =
  Pubsub.subscribe hub @@ fun sub ->
  let rec loop () =
    Pubsub.recv sub
    |> Effect.bind (fun event ->
           handle event |> Effect.bind loop)
  in
  loop ()
```

Use `Unbounded` only for low-volume signals where unbounded retention is an
intentional choice. `Drop_new` drops a new message for all current subscribers
when the hub is full. `Backpressure` waits before admitting a message, and
publisher cancellation while waiting cannot partially publish to some
subscribers.

Wrap Eio operations in `Effect.sync` at the leaf when they need typed failure
conversion or tracing names. If a protocol is reusable
and owns lifecycle semantics, prefer a focused module such as `Resource` or
`Pubsub` rather than a generic concurrency-data wrapper.

## Redacted Values

`Redacted.t` wraps sensitive values so that formatting and JSON output show
`<redacted>` instead of the underlying data. Equality and hash use the
original value, so redacted strings can still be used as map keys.

```ocaml
let token = Redacted.make ~label:"api_key" "secret-token"
let auth_header = "Bearer " ^ Redacted.value token
```

The type is abstract and has no `[@@deriving show]` hooks; accidental
formatter derivation is blocked at the API level. `wipe_unsafe` best-effort
erases the cell, but the value may still exist in other references.

When adding values to tracer attributes or logs, explicitly extract or
render them. The tracer attribute API remains `(string * string) list`;
wrap secrets in `Redacted.t` at the source and call `Redacted.value` or
`Format.asprintf "%a" Redacted.pp` only when constructing the attribute list.

## Trace Propagation

Tracing is configured on the runtime:

```ocaml
let rt =
  Runtime.create ~sw ~clock ~tracer:(Eta_otel.tracer exporter) ()
```

Observability is pay-as-you-go. A runtime created without tracer, logger, or
meter capabilities uses Eta's noop sinks and cuts off tracing/logging/metrics
inside the core interpreter before records enter eta-otel queues or OTLP/JSON
encoding. `Effect.named` still keeps Eta diagnostics such as defect span names
and annotations, so use it where that context is useful rather than as a
per-element marker in the hottest loops.

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
