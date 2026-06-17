# Eta

Eta is a small OCaml 5 effect/runtime library. It exposes a typed
`('a, 'err) Effect.t` for describing pure values, failures, concurrency,
resource scopes, and observability, plus backend-neutral interpreters.

Eta is shaped by TypeScript Effect and Scala ZIO, but it is not a
compatibility layer for their full API surface. Deliberate differences are
documented in [ZIO / Effect Boundaries](docs/zio-boundaries.md).
The recommended application style is documented in
[Eta API Style](docs/api-dx.md).

Core principle: **applications own state; Eta owns effect description and
interpretation.** There is no global environment, layer graph, service
locator, or state container. Pass dependencies as ordinary OCaml values.

Optional capabilities live in separate `eta_<feature>` opam packages. The
root `eta` package contains only the core effect model and interpreter
contract. Add `eta_eio` for an Eio backend, `eta_http` for HTTP, `eta_sql`
for SQLite, `eta_otel` for OpenTelemetry, and so on. See
[docs/packages.md](docs/packages.md) for the full map.

## Quick start

Install dependencies and build with Nix (recommended):

```sh
nix develop -c dune build @install
```

Or with opam:

```sh
opam install . --deps-only --with-test
dune build @install
```

A minimal executable uses `(libraries eta eta_eio eio_main)`:

```dune
(executable
 (name hello)
 (libraries eta eta_eio eio_main))
```

```ocaml
open Eta

let program () =
  let open Syntax in
  (let* n = Effect.sync_result (fun () -> Ok (1 + 1)) in
   if n < 3 then Effect.fail `Too_small else Effect.pure n)
  |> Effect.recover (fun `Too_small -> 3)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta.Runtime.run rt (program ()) with
  | Exit.Ok n -> Format.printf "%d@." n
  | Exit.Error _ -> assert false
```

`Eta.Runtime` is the backend-neutral interpreter; `Eta_eio.Runtime.create`
is the Eio-backed constructor. The root `eta` package does not include a
runtime backend.

## Features

Core effect model and runtime boundaries:

| Module | Purpose |
| --- | --- |
| `Effect` | Abstract description for pure values, typed failure, sync leaves, mapping/sequencing primitives, catch, timeout, race, repeat, retry, uninterruptible regions, scopes. |
| `Syntax` | Binding operators for `Effect.t`: `let*`, `let+`, `let@`, `and*`, and `and+`. |
| `Supervisor` | Scope-bound nursery for child effects with observable failures, typed await, and cancellation. |
| `Cause` | Slim failure tree: typed failure, unchecked exception, interruption, and parallel failures. |
| `Exit` | Runtime boundary result: success or failure cause. |
| `Runtime` | Backend-neutral interpreter for `Effect.t`, built from a runtime module. |
| `Duration` | Millisecond-precision durations. |
| `Schedule` | Pure recurrence descriptions for repeat and retry. |
| `Resource` | Cached effectful resources with explicit refresh and refresh-failure inspection. |
| `Capabilities` | Small object-type traits for runtime services and explicit dependencies. |
| `Trace_context` | W3C traceparent/tracestate/baggage extract and inject helpers for distributed tracing. |

Concurrency, observability, and data primitives in the root package:

| Module | Purpose |
| --- | --- |
| `Tracer` | In-memory and noop tracer implementations for tests and disabled tracing. |
| `Logger` | In-memory and noop logger implementations. |
| `Meter` | In-memory and noop meter implementations. |
| `Sampler` | Trace sampling policies: always-on, always-off, ratio, parent-based. |
| `Log_level` | Severity levels for log records. |
| `Random` | Deterministic random helpers over `Capabilities.random`. |
| `Queue` | Same-domain unbounded FIFO with close/error fences. |
| `Channel` | Same-domain bounded channel with backpressure. |
| `Pubsub` | Same-domain scoped broadcast hub with explicit overflow policy. |
| `Pool` | Same-domain bounded resource pool with lifecycle and health checks. |
| `Semaphore` | Cancellation-safe counting semaphore. |
| `Mutable_ref` | Named shared mutable cell backed by `Atomic.t`. |

Sensitive-value redaction lives in the optional `eta_redacted` package, not in
`eta` core.

## API surface footguns

- `Effect.sync` exceptions are unchecked defects (`Cause.Die`), not typed
  failures. Catch expected errors by returning `result` and lifting with
  `Effect.sync_result`. Use `Effect.from_result` only when the `result` has
  already been computed outside the synchronous leaf.
- `Effect.catch` handles typed failures only; it does not catch defects,
  interruption, or finalizer failures.
- `Effect.ignore_errors` is only for best-effort unit effects. It suppresses
  typed failures, but defects, interruption, and finalizer failures still
  surface.
- `Effect.result` turns the typed failure channel into an ordinary OCaml
  `result` value inside the workflow. It does not catch defects, interruption,
  or finalizer failures.
- `Effect.par`, `all`, `race`, and `for_each_par` run child effects as fibers on
  the current runtime substrate, not on CPU worker domains. Use `eta_par` for
  CPU parallelism.
- `Effect.uninterruptible` defers cancellation; it does not turn interruption
  into a typed failure.
- `Queue`, `Channel`, `Pubsub`, and `Pool` are same-runtime primitives. Do not
  pass them across `eta_par` domain boundaries.
- `Supervisor.scoped` children cannot escape their nursery; handles are
  rank-2 scoped to the body.
- `Runtime.run_exn` raises `Failure` for typed failures and interruption. Use
  `Runtime.run` when you need to inspect the cause.

## Native Parallelism

The optional `eta_par` package contains Eta's native worker-domain scheduler.
It is deliberately outside the root `eta` package so the core effect model can
be interpreted by other runtimes.

```ocaml
let pool = Eta_par.Island.Pool.create ~domains:2 ()

let program =
  Eta_par.Island.run ~name:"square" ~pool (fun n -> n * n) 7
```

Finite island batches use `Eta_par.Island.map`, `map_result`, or
`all_settled`. Island pools are explicit native resources; the root
`Eta.Runtime` does not carry an ambient island pool or a per-run island
override.

For structured CPU parallelism over arrays or recursive fork/join algorithms,
use `Eta_par.run`, `Eta_par.join`, `Eta_par.par_map`, and
`Eta_par.Iter`. See [Concurrency primitives in Eta](docs/concurrency-guide.md)
for the decision flow between `Effect.sync`, islands, fork-join parallelism,
and blocking work.

## Native Blocking Calls

The optional `eta_blocking` package contains bounded OS-thread worker pools for
synchronous native calls such as database engines, syscalls, and blocking C
libraries. Runtime packages provide the worker substrate; for example
`eta_eio` installs an Eio `run_in_systhread` runner by default.

Use `Eta_blocking.run` when the callback returns an ordinary value, and
`Eta_blocking.run_result` when the callback returns expected typed failures as
`result`.

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

Leaf effects use ordinary OCaml captures:

```ocaml
let current_user auth =
  [%eta.sync "auth.current_user" (Auth.current_user auth)]
```

This expands to `Effect.fn __POS__ __FUNCTION__ (Effect.named ... (Effect.sync ...))`, with a
zero-argument callback.

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

Use `Effect.with_resource` for body-bounded resource lifetimes. Finalizers run
on success, typed failure, unchecked defect, and cancellation.

```ocaml
let with_db =
  let acquire = Effect.named "db.open" (Effect.sync (fun () -> Db.open_)) in
  let release handle =
    Effect.named "db.close" (Effect.sync (fun () -> Db.close handle))
  in
  Effect.with_resource ~acquire ~release
```

Use `let@` from `Eta.Syntax` to keep callback-shaped lifecycle code flat:

```ocaml
let load_user id =
  let open Eta.Syntax in
  let@ db = with_db in
  Effect.sync_result (fun () -> Db.load_user db id)
```

Use `Effect.acquire_release` directly when a resource should live until an
enclosing runtime or `Effect.scoped` boundary rather than just one callback body.

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

The `{ run = ... }` body is intentional: it gives OCaml a rank-2 scope token, so
the type checker rejects returning a child handle after the nursery closes.

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
  let open Syntax in
  let rec loop () =
    let* event = Pubsub.recv sub in
    let* () = handle event in
    loop ()
  in
  loop ()
```

Use `Unbounded` only for low-volume signals where unbounded retention is an
intentional choice. `Drop_new` drops a new message for all current subscribers
when the hub is full. `Backpressure` waits before admitting a message, and
publisher cancellation while waiting cannot partially publish to some
subscribers.

Wrap Eio operations in `Effect.sync` at the leaf when they need Eta tracing
names or defect diagnostics. If a synchronous leaf has expected failures, return
an ordinary OCaml `result` and lift it with `Effect.sync_result`; exceptions
remain unchecked defects. If a protocol is reusable and owns lifecycle
semantics, prefer a focused module such as `Resource` or `Pubsub` rather than a
generic concurrency-data wrapper.

## Redacted Values

The optional `eta_redacted` package provides `Redacted.t`, which wraps
sensitive values so that formatting and JSON output show `<redacted>`
instead of the underlying data. Equality and hash use the original value,
so redacted strings can still be used as map keys.

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

Tracing is configured on the runtime. The root `eta` package ships built-in
noop and in-memory tracers:

```ocaml
let tracer = Eta.Tracer.in_memory ()

let rt =
  Eta_eio.Runtime.create ~sw ~clock ~tracer:(Eta.Tracer.as_capability tracer) ()
```

Production exporters such as OpenTelemetry live in optional packages:

```ocaml
let rt =
  Eta_eio.Runtime.create ~sw ~clock ~tracer:(Eta_otel.tracer exporter) ()
```

Observability is pay-as-you-go. A runtime created without tracer, logger, or
meter capabilities uses Eta's noop sinks and cuts off tracing/logging/metrics
inside the core interpreter before records enter eta_otel queues or OTLP/JSON
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

Span attributes can be attached one at a time or as a list:

```ocaml
let load_rows : (int list, [ `Fetch_failed ]) Effect.t =
  Effect.pure [ 1; 2; 3 ]

let load_assets =
  Effect.fn
    ~attrs:[ ("component", "ingest"); ("source", "yahoo") ]
    __POS__ __FUNCTION__
    (Effect.with_result_attrs
       ~ok_attrs:(fun rows ->
         [ ("result", "ok"); ("row_count", string_of_int (List.length rows)) ])
       ~err_attrs:(fun `Fetch_failed -> [ ("result", "fetch_failed") ])
       load_rows)
```

Use `Effect.event` for structured markers on the active span:

```ocaml
let symbol = "AAPL"

let progress =
  Effect.event ~attrs:[ ("asset", symbol) ] "ingest.assets.progress"
```

`Effect.event` is not a log record. It is dropped when no span is active. Put
`with_result_attrs` inside `Effect.named` or `Effect.fn`; outcome attributes are
also dropped when the wrapped effect settles outside an active span.

At service boundaries, extract W3C headers and install the context around the
request effect:

```ocaml
let handle headers =
  let body = Effect.named_kind ~kind:Capabilities.Server "http.request" work in
  match Trace_context.extract headers with
  | None -> body
  | Some ctx -> Effect.with_context ctx body
```

For eta_http request values, use the request helper instead of reaching into
the header list:

```ocaml
let handle_request request =
  let body = Effect.named_kind ~kind:Capabilities.Server "http.request" work in
  match Eta_http.Trace_context.extract_request request with
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

Eta uses a Nix-managed OxCaml 5.2.0+ox toolchain. Enter the shell with:

```sh
nix develop
```

First-time setup creates the local opam switch:

```sh
eta-oxcaml-init
```

The handoff gate is:

```sh
nix develop -c dune runtest --force
```

Build all installable packages without running tests:

```sh
nix develop -c dune build @install
```

Benchmarks are opt-in and are not run by `dune runtest`:

```sh
nix develop -c bash bench/run.sh --quick   # quick snapshot
nix develop -c dune build @bench           # build runtime benchmark executables
```

See [bench/README.md](bench/README.md) for the JSON format, comparison tool,
and bisect workflow.

Without Nix, use an OCaml 5.2.0+ox switch, install dependencies, then run the
same Dune gates:

```sh
opam install . --deps-only --with-test
dune build @install
dune runtest --force
```

Footguns:

- `dune build` without an alias also builds tests, benchmarks, and research
  suites. Use `dune build @install` when you only need installable packages.
- `nix develop .#mainline` is an upstream-OCaml comparison shell, not the
  primary development shell.
- `test/http` is the low-level protocol test target. `test/http_eio` is the
  green Eio transport gate.

The research journal is intentionally ignored by Git. It records the full
project history and local design reasoning, but it is not part of the
published package.
