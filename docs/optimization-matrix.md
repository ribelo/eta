# Package Optimization Matrix

This file tracks which packages have already had an optimization pass. It does
not record benchmark numbers; benchmark history stays under `bench/results/`.

## Status Key

| Status | Meaning |
| --- | --- |
| Done | Package had a focused optimization pass and has matching tests/benchmarks. |
| Partial | Some hot paths were tackled, but the package still has an explicit remaining area. |
| Ready | Bench/test surface is good enough to start an optimization pass. |
| Needs harness | Add or tighten tests/benchmarks before optimizing. |
| Later | Defer until a dependency package is done or the package becomes a bottleneck. |

## Matrix

| Package | Role | Status | Already Tackled | Tracking Signal | Next Action |
| --- | --- | --- | --- | --- | --- |
| `eta` | Core runtime, effects, schedules, queues, channels, pools, observability primitives. | Done | Core runtime paths, concurrency primitives, queue/channel surface, and queue benchmarks. | `test/eta`, `eta.queue.*`, `effect.*`, `realuse.*`, `overhead.*`. | Reopen only for regressions found by downstream packages. |
| `eta_http` | HTTP/1.1, HTTP/2, TLS/OpenSSL, body streaming, retries, observability, WebSocket. | Partial | HTTP/1.1 and HTTP/2 were optimized. WebSocket has tests and benchmarks but has not had its own optimization pass yet. | `test/http`, `http.ws.*`, `@interop`, `@cve-regress`, `@http-bench`. | Finish the WebSocket pass, then mark the package Done. |
| `eta_stream` | Pull streams, sinks, mailboxes, merge, parallel stream combinators, file streams. | Ready | Benchmark harness exists; no package-level optimization pass recorded here. | `test/stream`, `eta_stream.*`. | Tackle after WebSocket if we finish eta_http first; otherwise this is the next package-level target. |
| `eta_schema` | Pure schema decode/encode/transform and JSON representation. | Ready | Benchmarks exist for decode, encode, transform, policy, failures, JSON rendering. | `test/schema`, `eta_schema.*`. | Optimize after stream because AI/provider packages depend on schema shape. |
| `eta_schema_test` | Alcotest helpers for schema packages. | Later | No optimization pass needed unless test runtime becomes noisy. | Package tests. | Defer; utility package. |
| `eta_redacted` | Redacted sensitive values and rendering helpers. | Later | Small surface; no optimization pass recorded. | `test/redacted`. | Defer unless provider benchmarks show redaction overhead. |
| `eta_test` | Test clock, deterministic random, expectations, runtime fixtures. | Later | Test support only. | `test/test`. | Defer; optimize only if it slows the suite. |
| `Eta.Par` | Rayon-style fork/join and array parallelism. | Ready | Benchmarks exist; no package-level optimization pass recorded here. | `lib/par/bench`, `bench/runtime_par`. | Tackle when CPU parallel workloads become the focus; high leverage but less urgent for realtime audio substrate than stream/WS. |
| Eta SQL | SQLite connector, SQL builders, Eta pool, migrations. | Ready | Dependency cleanup done; no optimization pass recorded here. | `test/sql`, `lib/sql/bench`. | Tackle after substrate/provider packages unless SQLite latency is a product priority. |
| `eta_otel` | OTLP/JSON exporter, batching, stream merging, retry, transport. | Needs harness | Audit exists; exporter path depends on eta_stream and eta_http. | `test/otel`, current OTLP adapter benchmark. | Optimize after stream because batching/export pipelines use stream primitives. |
| `eta_ai` | Core AI vocabulary, SSE parser, telemetry wrappers, redacted API keys. | Needs harness | No package-level optimization pass recorded; depends on eta_http and eta_stream. | `test/ai/core`, provider fixtures. | Add focused benches for SSE parse and message/content encoding before optimizing. |
| `eta_ai_openai_codec` | Shared OpenAI wire codec helpers. | Needs harness | No optimization pass recorded. | `lib/ai/openai_codec/bench`, codec tests. | Add/confirm codec benches, then optimize before provider packages. |
| `eta_ai_openai` | OpenAI Responses, Chat Completions, streaming, Realtime session API. | Later | Realtime substrate work added surface; no optimization pass recorded. | `test/ai/openai`, provider fixtures, live reach probe. | Defer until eta_ai and OpenAI codec hot paths are tackled. |
| `eta_ai_anthropic` | Anthropic Messages provider. | Later | No optimization pass recorded. | Provider fixture tests. | Defer until core AI/codec passes are done. |
| `eta_ai_openai_compat` | OpenAI-compatible provider wrapper. | Later | No optimization pass recorded. | Provider fixture tests. | Defer until shared codec/core AI passes are done. |
| `eta_ai_openrouter` | OpenRouter provider behavior and routing/errors. | Later | No optimization pass recorded. | Provider fixture tests. | Defer until shared codec/core AI passes are done. |
| `ppx_eta` | Syntax helpers for Eta effects and Eta SQL table declarations. | Needs harness | No optimization pass recorded. | PPX tests and compile-time fixtures. | Track compile-time only; optimize after runtime packages unless compile benches regress. |

## Recommended Order

1. `eta_http` WebSocket pass.
2. `eta_stream`.
3. `eta_schema`.
4. `eta_ai_openai_codec`.
5. `eta_ai`.
6. Provider packages: `eta_ai_openai`, `eta_ai_anthropic`, `eta_ai_openai_compat`, `eta_ai_openrouter`.
7. `eta_otel`.
8. `Eta.Par` or Eta SQL, depending on whether CPU workloads or SQLite workloads are the next product bottleneck.
9. Utility packages: `eta_redacted`, `eta_test`, `eta_schema_test`, `ppx_eta`.

The immediate recommendation is to finish WebSocket inside `eta_http` before
moving on. HTTP/1.1 and HTTP/2 are done, but WebSocket is new realtime substrate
code with fresh tests and benchmarks; optimizing it closes the package cleanly.
If the goal is strictly to leave eta_http alone, start with `eta_stream` next
because it sits under WebSocket inbound flow, AI SSE parsing, and OTel batching.

