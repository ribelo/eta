# Eta Package Map

Eta ships as a monorepo of opam packages. Each package publishes exactly one
public Dune library with a matching OCaml top-level module. Pick only the
packages you need.

- opam enforces installation at *package* granularity.
- OCaml's native linker drops unreachable `.cmx` modules, so unused modules do
  not bloat the binary.
- Transitive opam dependencies must still be installed, even if your code never
  calls them.

## Core boundary

`eta` is the effect description layer: `Effect`, `Runtime`, `Cause`, `Exit`,
schedules, resources, supervisors, channels, queues, and the runtime contract.
It depends only on OCaml and Dune.

`eta` describes effects; it does not run them. A runnable program needs a
runtime backend:

| target | package | it adds |
| --- | --- | --- |
| native / Eio | `eta_eio` | `eio`, `cstruct` |
| browser / js_of_ocaml | `eta_jsoo`, `eta_js` | `js_of_ocaml` |
| native CPU parallelism | `eta_par` | `eta_blocking` |

> Footgun: an executable that depends only on `eta` has no concrete
> `Runtime.create` and no way to interpret effects. Add `eta_eio` (or
> `eta_jsoo`) before writing `Eio_main.run` or `Eta_eio.Runtime.create`.

## Discoverability

```sh
ocamlfind list | grep '^eta'
ocamlfind query eta_http -recursive
ocamlfind query eta_http -format "%d/%a"
```

Every package records a one-line `description` in its META, so
`ocamlfind list` is self-explanatory.

## Package index

The `extra deps` column lists direct opam dependencies beyond `eta`, OCaml, and
Dune, excluding `with-test` and `with-doc` dependencies. `—` means the package
depends only on `eta` (or on nothing, for the pure DSL/PPX packages).

### Core and runtimes

| opam package | OCaml module | what it adds | extra deps |
| --- | --- | --- | --- |
| `eta` | `Eta` | effect description, runtime contract, channels, queues, supervisors, schedules | — |
| `eta_blocking` | `Eta_blocking` | bounded OS-thread worker pools | — |
| `eta_eio` | `Eta_eio` | Eio runtime host and Eio bridges | `eta_blocking`, `eio`, `cstruct` |
| `eta_par` | `Eta_par` | native fork-join and typed island offload | `eta_blocking` |
| `eta_utop` | `Eta_utop` | UTop convenience helpers | `eta_blocking`, `eta_eio`, `eio_main` |

### Data and schema

| opam package | OCaml module | what it adds | extra deps |
| --- | --- | --- | --- |
| `eta_cache` | `Eta_cache` | effect-integrated keyed cache | — |
| `eta_stream` | `Eta_stream` | pull streams, mailboxes, bounded queues | `eio`, `cstruct` |
| `eta_redacted` | `Eta_redacted` | secret-wrapping types | — |
| `eta_schema` | `Eta_schema` | lightweight schemas and JSON codecs | — |
| `eta_schema_test` | `Eta_schema_test` | Alcotest helpers for schema tests | `eta_schema`, `alcotest` |

### HTTP

| opam package | OCaml module | what it adds | extra deps |
| --- | --- | --- | --- |
| `eta_http` | `Eta_http` | backend-neutral HTTP model, client contract, URL/TLS policy, body streams, retry helpers | `yojson`, `domain-name`, `ipaddr`, `bigstringaf`, `decompress` |
| `eta_http_h1` | `Eta_http_h1` | HTTP/1 parser/writer helpers | `eta_http` |
| `eta_http_h2` | `Eta_http_h2` | HTTP/2 protocol state machine | `eta_http`, `bigstringaf`, `cstruct`, `angstrom`, `faraday` |
| `eta_http_tls_openssl` | `Eta_http_tls_openssl` | OpenSSL TLS state-machine bindings | `cstruct`, `conf-pkg-config`, `conf-openssl` |
| `eta_http_ws` | `Eta_http_ws` | WebSocket codec and handshake helpers | `base64` |
| `eta_http_eio` | `Eta_http_eio` | Eio transport adapter: DNS, TCP, TLS, HTTP/1.1, HTTP/2, WebSocket | `eta_blocking`, `eta_eio`, `eta_http`, `eta_http_h1`, `eta_http_h2`, `eta_http_tls_openssl`, `eta_http_ws`, `eta_stream`, `eio`, `eio_main`, `bigstringaf`, `cstruct`, `domain-name`, `ipaddr`, `faraday`, `angstrom`, `yojson` |
| `eta_http_service` | `Eta_http_service` | routing, extractors, JSON responses, middleware helpers | `eta_http`, `eta_router`, `yojson` |
| `eta_http_service_eio` | `Eta_http_service_eio` | Eio serving helpers for eta-http-service | `eta_http`, `eta_http_eio`, `eta_http_service`, `eio` |
| `eta_router` | `Eta_router` | zero-copy URL path router | — |

`eta_http` is deliberately backend-neutral: it defines the shared HTTP model,
client contract, protocol helpers, and TLS policy surface, but it cannot open a
socket or make a network request without `eta_http_eio` or another adapter.

### SQL and connectors

| opam package | OCaml module | what it adds | extra deps |
| --- | --- | --- | --- |
| `eta_sql_dsl` | `Eta_sql_dsl` | backend-agnostic typed SQL builder | — |
| `eta_sql_driver` | `Eta_sql_driver` | shared blocking-pool and cancellation helpers | `eta_blocking` |
| `eta_sql` | `Eta_sql` | SQLite connector with typed effect surface | `eta_blocking`, `eta_sql_driver`, `eta_sql_dsl`, `conf-pkg-config`, `conf-sqlite3` |
| `eta_turso` | `Eta_turso` | Turso SQLite-compatible connector | `eta_blocking`, `eta_sql_driver`, `eta_sql`, `eta_sql_dsl` |
| `eta_duckdb` | `Eta_duckdb` | DuckDB connector | `eta_blocking`, `eta_sql_driver`, `eta_sql_dsl` |
| `eta_ladybug` | `Eta_ladybug` | LadybugDB graph connector | `eta_blocking` |

`eta_sql` and `eta_turso` keep separate C stubs because their foreign loading
contracts differ. `eta_sql` links against system SQLite via `pkg-config`;
`eta_turso` loads `libturso_sqlite3` at runtime with `RTLD_DEEPBIND` isolation
where supported.

### AI providers

| opam package | OCaml module | what it adds | extra deps |
| --- | --- | --- | --- |
| `eta_ai` | `Eta_ai` | provider-agnostic chat/streaming vocabulary, SSE parser, telemetry wrappers | `eta_redacted`, `eta_http`, `yojson` |
| `eta_ai_openai_codec` | `Eta_ai_openai_codec` | shared OpenAI wire codecs | `eta_ai`, `base64` |
| `eta_ai_openai` | `Eta_ai_openai` | OpenAI Responses/Chat Completions provider | `eta_ai`, `eta_ai_openai_codec`, `eta_redacted`, `eta_http`, `base64`, `yojson` |
| `eta_ai_openai_realtime_eio` | `Eta_ai_openai_realtime_eio` | Eio WebSocket adapter for OpenAI Realtime | `eta_ai`, `eta_ai_openai`, `eta_http`, `eta_http_eio`, `eta_redacted`, `eta_stream`, `eio` |
| `eta_ai_anthropic` | `Eta_ai_anthropic` | Anthropic Messages provider | `eta_ai`, `eta_redacted`, `eta_http`, `yojson` |
| `eta_ai_openrouter` | `Eta_ai_openrouter` | OpenRouter provider | `eta_ai`, `eta_ai_openai_codec`, `eta_redacted`, `eta_http`, `base64`, `yojson` |
| `eta_ai_openai_compat` | `Eta_ai_openai_compat` | OpenAI-compatible adapter (Together, Groq, Fireworks, ...) | `eta_ai`, `eta_ai_openai_codec`, `eta_redacted`, `eta_http`, `yojson` |

Provider packages depend on `eta_ai` and `eta_http`. They do not pull a default
transport; applications pass an explicit `Eta_http.Client.t` from the adapter
they use.

### Observability

| opam package | OCaml module | what it adds | extra deps |
| --- | --- | --- | --- |
| `eta_otel` | `Eta_otel` | OTLP/JSON exporter for tracer, logger, and meter | `eta_stream`, `eta_http`, `yojson` |

`eta_otel` is an exporter, not a runtime. It needs a `runtime_factory` (usually
from `eta_eio`) and usually an `eta_http_eio` client to send data.

### Testing and UX

| opam package | OCaml module | what it adds | extra deps |
| --- | --- | --- | --- |
| `eta_linux_input` | `Eta_linux_input` | Linux evdev and uinput helpers | `eta_blocking` |
| `eta_test` | `Eta_test` | virtual clock, deterministic random, cause-aware Alcotest assertions | `eta_eio`, `eio`, `eio_main`, `alcotest` |
| `ppx_eta` | `Ppx_eta` | syntax helpers and SQL table declaration sugar | `ppxlib` |

### js_of_ocaml

| opam package | OCaml module | what it adds | extra deps |
| --- | --- | --- | --- |
| `eta_jsoo` | `Eta_jsoo` | js_of_ocaml runtime backend | `js_of_ocaml` |
| `eta_js` | `Eta_js` | js_of_ocaml facade | `eta_jsoo`, `js_of_ocaml` |
| `eta_js_stream` | `Eta_js_stream` | pull streams for js_of_ocaml targets | `eta_js` |
| `eta_js_test` | `Eta_js_test` | test helpers for `eta_js` | `eta_js`, `js_of_ocaml` |
| `eta_http_js` | `Eta_http_js` | Fetch client adapter for eta-http | `eta_http`, `eta_jsoo`, `js_of_ocaml` |

> Footgun: the JS packages are disabled in the `5.2.0+ox` switch used by the
> default Nix/OxCaml shell (`enabled_if (<> %{ocaml_version} 5.2.0+ox)`). Build
> and test them through the flake's mainline shell:
> `nix develop .#mainline -c dune runtest test/http_js --force`.

## How OCaml's tree-shaking actually works

OCaml has dead-code elimination, but it is coarser than JavaScript bundlers.
Two levels matter:

1. **Within a library.** The native linker drops `.cmx` modules that are not
   reachable from `main`. If `eta_http` contains many modules and your binary
   only touches five, only those five (plus their transitive callees) end up in
   the executable.

2. **Across libraries.** The granularity is the *ocamlfind package*. The moment
   you add `(libraries eta_http)` to your `dune` file, every package listed in
   `eta_http`'s `requires` must be installed on the system. Unused ones still
   will not bloat the binary (level 1 still applies), but they have to be
   present.

The practical rule:

> Heavy dependencies belong in their own ocamlfind package. Do not depend on
> `eta_http` if you only need `eta_stream`.

Eta is structured so this rule is easy to follow. A small CLI uses
`(libraries eta)` for the core effect model, then adds `eta_eio` to run it. Add
`eta_http` when you need the HTTP model, client contract, or protocol helpers;
add `eta_http_eio` when you need Eio network I/O; add `eta_sql` only when you
need SQLite; and so on.

## Recipes

### Effect core only (not runnable alone)

```dune
(executable (name app) (libraries eta))
```

Cost: no runtime backend.

### Native Eio runtime

```dune
(executable (name app) (libraries eta eta_eio))
```

Adds: Eio runtime host.

### Native blocking calls

```dune
(executable (name app) (libraries eta eta_blocking eta_eio))
```

Adds: blocking worker pool plus Eio-backed runner installed by `eta_eio`.

### Effect core + streams

```dune
(executable (name app) (libraries eta eta_stream eta_eio))
```

Adds: `cstruct` and Eio.

### HTTP client

```dune
(executable (name app) (libraries eta eta_http eta_http_eio))
```

`eta_http` gives the shared API and protocol layer; `eta_http_eio` gives the
transport. Depending on `eta_http` alone will not open a socket or make a
request.

### HTTP client with retries and tracing

```dune
(executable (name app) (libraries eta eta_http eta_http_eio eta_otel))
```

`eta_otel` needs a runtime factory and an HTTP client; see `lib/otel/README.md`.

### SQLite

```dune
(executable (name app) (libraries eta eta_blocking eta_eio eta_sql))
```

`eta_sql` needs a blocking pool; `eta_eio` provides the runtime host.

### LLM chat using OpenAI

```dune
(executable (name app) (libraries eta eta_ai eta_ai_openai))
```

Adds: everything in the `eta_http`/`eta_http_eio` chain, `eta_stream`, `eio`,
`yojson`, and `base64`.

### Tests with the virtual clock and cause-aware assertions

```dune
(test (name run) (libraries eta eta_test alcotest))
```

`eta_test` already depends on `eta_eio` and `eio_main`.

## Drivers

Optional external-engine integrations live under `drivers/`. They are *not*
opam packages and are invisible to `ocamlfind`. They depend on Eta; Eta core
libraries under `lib/` must never depend on them.

## Limits and footguns

- **Package granularity is the opam package.** Adding `eta_http` forces every
  dependency declared by `eta_http` and its transitive opam packages to be
  installed, even if your program only reaches one OCaml module.
- **`eta` alone does not run.** You must pair it with `eta_eio`, `eta_jsoo`,
  or another implementation of `Eta.Runtime_contract.RUNTIME`.
- **`eta_http` is backend-neutral, not dependency-free.** It has no Eio/socket
  ownership, but it currently carries protocol codec dependencies and OpenSSL
  C stubs for the shared TLS policy surface. Real network I/O needs
  `eta_http_eio` or a custom adapter.
- **`eta_otel` is an exporter, not a runtime.** It needs a `runtime_factory`
  (typically `Eta_eio.Runtime.create`) and usually an `eta_http_eio` client.
- **Native C-stub packages split build-time and runtime requirements.**
  `eta_sql` and `eta_http` use `pkg-config` at build time for SQLite and
  OpenSSL. `eta_turso`, `eta_duckdb`, and `eta_ladybug` have C stubs that load
  their native database libraries at runtime instead of through opam `conf-*`
  packages.
- **JS packages are disabled under +ox.** They are skipped in the pinned
  `5.2.0+ox` Nix shell.
- **`ppx_eta` is compile-time tooling.** It adds `ppxlib` to the build; the
  generated code may still reference the normal runtime libraries used by the
  source being rewritten.
