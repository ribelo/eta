# Test Backend Split

Eta tests are split by behavior, not by directory convenience.
Backend-neutral Eta contracts live in shared suites and are instantiated by a
backend runner. Tests stay in package-local suites only when they verify a
specific host runtime, native driver, C stub, process loader, js_of_ocaml
output, socket/TLS/flow ownership, or opt-in fuzz infrastructure.

## Core Runtime

`test/core_common` owns backend-agnostic primitive coverage that must run
through `Eta_eio`. `test/runtime_common` owns backend-agnostic runtime API
coverage, including `run`, `run_exn`, cancellation-aware resource release,
supervisor basics, and runtime-contract integration.

Shared primitive coverage includes:

- Effect constructors/combinators, typed failures, defects, finalizers,
  catch behavior, interruption semantics, dependency passing, parallel
  combinators, virtual clocks, race cleanup, timeout/finalizer ordering,
  retry/repeat schedules, resources, observability, daemon behavior, and
  uninterruptible behavior.
- Mutable_ref, Queue, Channel, Semaphore, Pubsub, Pool, Clock, Scope,
  Resource, Supervisor, Duration, Schedule, String_helpers, Eta_redacted,
  Runtime contract, Portable_queue, Properties, stress/resource-leak
  regressions, and upstream-invariant regressions.

`test/blocking_common` owns backend-agnostic `eta_blocking` coverage:
blocking run/result/result_timeout semantics, timeout cancellation hooks,
queued-work cancellation, reject-policy accounting, started-work
nonpreemption, shutdown rejection/drain behavior, worker re-entry guards, and
ordinary user exception classification.

`test/eta` remains for Eio-specific or currently Eio-only probes that directly
use `Eio.Cancel`, `Eio.Switch`, raw `Eio.Promise`, `Eio_unix` wall-clock
sleeps, host scheduler interleavings, raw Eio cancellation identity, native
host runners, domain-local runtime frames, and raw Eio cancellation/status
classification. Keep moving Eta-owned behavior to `test/core_common`; keep
only raw host-runtime probes in `test/eta`.

## HTTP

`test/http_common` owns HTTP behavior independent of the concrete runtime
backend and is instantiated by `test/http_eio`.

Shared HTTP coverage includes core smoke, helpers, URL parsing, retry
contracts, body stream ownership, codecs/transducers, HTTP/1 parser/writer
logic, WebSocket frame invariants, HTTP/2 admission/stream-state/frame/writer
logic, ALPN/TLS policy, observability, and in-memory HTTP/2 multiplexer
behavior through Eta effects.

`test/http` remains the Eio-specific HTTP suite. Its remaining tests depend on
raw `Eio.Flow`, `Eio.Promise`, `Eio.Stream`, `Eio.Switch`, `Eio_mock.Flow`,
scripted flows, live TCP sockets, HTTP client/server transport ownership,
blocked writes, cancellation propagation, OpenSSL/TLS ownership, DNS, ALPN,
and connection-pool or multiplexer implementation details that currently own
Eio flows or Eio cancellation behavior. Do not move or delete these tests
unless Eta grows a backend-neutral transport API with the same ownership,
cancellation, socket, TLS, and flow-failure contracts.

`test/http/tls` is negative compile-time coverage for TLS configuration. It
runs `run_negative_compile.sh` against fixtures that must fail to compile.
Positive backend-neutral TLS policy checks live in `test/http_common`;
Eio/OpenSSL integration checks live in `test/http`.

`test/http_fuzz` is Crowbar fuzzing infrastructure, not an Alcotest
runtime-backend suite. It is intentionally driven through opt-in aliases:
`@test/http_fuzz/fuzz-smoke` and `@test/http_fuzz/fuzz`. The fuzz targets cover
HTTP/1 parser spans, HTTP/1 writer agreement, WebSocket codec/rejection
behavior, and HTTP/2 security/header/stream-state invariants. The HTTP/1
flow-writer target links Eio because that public writer accepts an
`Eio.Flow.sink`.

## Streams

`test/stream_common` owns Eta stream behavior independent of a concrete
runtime backend and is instantiated by `test/stream_eio`.

Shared stream coverage includes pure stream construction and combinators,
`Eta_stream.Stream.from_queue`, `Eta_stream.Mailbox`, and
`Eta_stream.Drain_counter`.

`test/stream` remains Eio-specific for `Eta_stream.Stream.from_file`, which
accepts `Eio.Path.t` and uses Eio file APIs. If Eta introduces a
backend-neutral file/path abstraction, the remaining `from_file` scenarios
should move into `test/stream_common`.

`test/js_stream` is `Eta_js_stream` js_of_ocaml integration coverage. It
compiles the stream facade to JavaScript and runs it under Node through
`Eta_js_test.main`. Native `Eta_stream` behavior that can be shared lives in
`test/stream_common`; the JS suite validates facade modules, js_of_ocaml
compilation, and Node runtime behavior.

## JavaScript

`test/js_jsoo` is js_of_ocaml integration coverage, not a native backend
matrix suite. The executables compile to JavaScript with
`js_of_ocaml --effects=cps` and run under Node.

`test_eta_jsoo.ml` checks the JavaScript-native runtime wrapper: timer delay,
timeout/finalizer behavior in the JS event loop, `Eta_jsoo.Private.await`
cancellation hooks, runtime locals, stream FIFO behavior, and daemon drain
through the JS runtime contract.

`test_eta_js_jsoo.ml` checks the `Eta_js` facade in JavaScript: effect
construction, typed failures, defects, finalizers, retry/repeat, concurrency
combinators, and queue/channel/semaphore/pubsub/supervisor facades. Equivalent
native Eta-owned semantics live in shared Eio suites.

## AI

Most `eta_ai` core scenarios live in `test/ai_common` and are instantiated by
`test/ai_eio`. Those tests cover vocabulary, provider records/codecs, toolkit
validation, SSE stream parsing/closing, and telemetry through Eta runtime
adapters.

Provider suites are backend-neutral Eta behavior and are instantiated by their
`run_eio.ml` runners:

- `test/ai/anthropic`: provider configuration, request encoding, fixture
  decoding, custom Eta HTTP clients, stream decoding, provider errors,
  prompt-cache headers, and telemetry span suppression.
- `test/ai/openai`: provider configuration, chat/responses/embeddings/image/
  audio/transcription/realtime request encoding, fixture decoding, custom Eta
  HTTP clients, stream handling, provider errors, and telemetry span
  suppression.
- `test/ai/openai_compat`: provider configuration, request construction,
  fixture decoding, custom Eta HTTP clients, stream decoding, provider
  errors, and telemetry span suppression.
- `test/ai/openrouter`: provider headers, routing and request encoding,
  fixture decoding, custom Eta HTTP clients, stream errors, embeddings, task
  APIs, binary runners, and telemetry span suppression.

`test/ai/core` keeps its Eio-specific oversized HTTP error-body test because it
builds an `Eio_mock.Net` H1 transport and an
`Eta_http_eio.Client.make_h1 ~sw ~net` client. That behavior depends on raw
Eio networking fixtures. The `negative/` compile tests also remain there; they
are compiler/package boundary checks for secret redaction and do not exercise
either runtime backend.

## SQL And Connectors

`test/sql_common` covers the backend-neutral SQL DSL/rendering contract through
`eta_sql_dsl` and is instantiated by `test/sql_eio`. It covers pure query
rendering, schema rendering, row/value helpers, and source invariants for the
DSL builder implementation without inheriting an Eio/SQLite dependency.

`test/sql_driver` covers the backend-neutral SQL-driver blocking contract for
the Eio backend: rejecting detach-started blocking pools and invoking
cancellation hooks on timed blocking work. This package has no remaining
raw-backend-specific tests.

`test/sql` remains native-specific. It exercises `eta_sql` SQLite C stubs,
SQLite file paths, migration source files and symlinks, native
timeout/interrupt behavior, pool behavior, and connector source-file
invariants. Keep those cases explicitly registered there unless a real
backend-neutral SQL execution surface is introduced.

`test/connectors` remains a native integration suite. It exercises DuckDB,
Turso, and Ladybug connector packages, each of which loads external native
driver libraries and validates connector-specific result decoding, prepared
statement cleanup, extension loading, timeouts, and handle ownership.

`test/connectors_loader` remains native-loader-specific. It builds fake shared
libraries, sets `LD_LIBRARY_PATH`, and verifies dynamic loader fallback, symbol
ownership, native pointer lifetime, and GC-root behavior for DuckDB, Turso, and
Ladybug bindings.

`test/duckdb` remains DuckDB-native-specific. It checks DuckDB SQL behavior,
dynamic loader failure paths, appender/row cursor ownership, transaction SQL,
pool shutdown around active native connections, and source-file invariants for
the DuckDB connector implementation.

`test/ladybug_leak` remains a native mock-library integration suite. It sets a
process-wide `ETA_LADYBUG_LIBRARY` before the one-shot Ladybug loader runs,
uses `ladybug_mock_lib.c`, and verifies native query-result cleanup, close
coordination, and timeout behavior through mock state files.

`test/turso_race` remains a native mock-library race test. It sets
`ETA_TURSO_LIBRARY`, loads `turso_mock_lib.c`, and checks that closing a Turso
connection does not destroy the native database while a step is active.

## OTEL

In-memory OTEL behavior lives in `test/otel_common` and is instantiated by
`test/otel_eio`. That shared suite covers tracer span context, logger
records/span IDs, metric aggregation, and OTLP JSON encoding that does not
require a live Eio exporter.

`test/otel` remains Eio-specific for exporter integration. Its remaining tests
construct `Eta_otel.create ~sw ~net ~clock`, start local TCP response servers,
talk to optional motel on `127.0.0.1:27686`, and exercise exporter queue,
retry, backpressure, self-span, self-metric, and live OTLP behavior.

## Optional Runtime Packages

`test/par_common` owns pure `Eta_par` scheduler and parallel-iterator
correctness tests. The suite does not depend on Eta runtime primitives, but it
is still instantiated under `test/par_eio` so package-level coverage follows
the native backend matrix.

`test/par` remains the Eio-specific island integration suite. Those tests
create `Eta_eio.Runtime`, use Eio switches/backends, and exercise
`Eta_par.Island` through Eta effects. Do not claim them as backend-neutral
until island execution has a first-class backend-neutral runtime contract.

## Test Helpers And PPX

`test/test_common` owns runtime-neutral `eta_test` helper coverage and runs it
through the shared Eio runner:

- `Eta_test.Expect` assertions for success, typed failures, defects, and
  interrupts.
- `Eta_test.Test_random.set_seed` deterministic schedule jitter replay.
- Seeded runtime jitter replay through backend-specific test-clock runtimes.
- Backend-neutral test-clock wake ordering and cascading virtual sleeps through
  the runtime adapter.
- Backend-neutral logger, tracer, and combined observed-runtime wiring.

`test/test` remains Eio-specific because the current public `eta_test` helpers
expose `Eio.Switch.t`, `Eio.Promise.t`, `Eio.Fiber.yield`, and
`Eta_eio.Runtime.create ~sleep` directly. Those tests cover the Eio-shaped
public helper surface.

`test/ppx_common` owns PPX-generated Eta runtime behavior and runs it through
the Eio-backed runtime. It covers `[%eta.fn ...]` spans, `[%eta.sync ...]`
leaf spans, and `[%eta.sql.table]` generated SQL metadata without opening
SQLite or running database effects. There is no direct `test/ppx` suite.

`test/schema_common` is instantiated by `test/schema_eio`. It covers Eta-owned
schema and JSON behavior, including typed decode/encode failures and
`decode_with_policy` effects. `Eta_schema_test` now evaluates effects through
an explicit backend runner.
