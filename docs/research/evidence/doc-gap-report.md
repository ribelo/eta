# Eta Documentation Gap Report

Scope: README.md, docs/*.md, lib/*/README.md, lib/eta/*.mli, AGENTS.md, dune-project.
Severity: **must-fix** = broken/misleading commands or examples; **should-fix** = missing/incomplete/contradicted clarity; **note** = minor polish.

---

## README.md

- **must-fix** — First example (`open Eta` + `Runtime.create ~sw ~clock:...`) will not compile. `Eta.Runtime` exposes `create_with_runtime`/`Runtime.Make`; the runnable constructor is `Eta_eio.Runtime.create`. Same pattern repeats in the OTel and Redacted examples.
- **must-fix** — Feature table lists `Redacted` as a core `Eta` module, but it lives in the optional `eta_redacted` package (`Eta_redacted`).
- **should-fix** — Opening description should state explicitly: small OCaml 5 effect/runtime library; applications own state; Eta owns effect description and interpretation; optional capabilities live in `eta_<feature>` packages.
- **should-fix** — Feature table omits public core modules in `lib/eta/`: `Channel`, `Queue`, `Pubsub`, `Pool`, `Semaphore`, `Mutable_ref`, `Sampler`, `Random`, `Logger`, `Meter`, `Log_level`.
- **should-fix** — Native Parallelism says `eta_par` is "deliberately outside the root `eta` package"; AGENTS.md says the opposite. Reconcile against `dune-project`/`lib/par`.

## AGENTS.md

- **must-fix** — Claims `Eta.Par` is in root `eta`. It is a separate `eta_par` package per `dune-project` and `lib/par/`.
- **should-fix** — Core module list omits `Syntax`, `Supervisor`, `Channel`, `Queue`, `Pubsub`, `Pool`, `Semaphore`, `Sampler`, `Logger`, `Meter`, `Log_level`, `Mutable_ref`, `Random`, `Trace_context`.

## docs/packages.md

- **must-fix** — Omits real packages from `dune-project`: `eta_http_eio`, `eta_sql_dsl`, `eta_sql_driver`, `eta_duckdb`, `eta_turso`, `eta_ladybug`, `eta_utop`, `eta_js`, `eta_jsoo`, `eta_js_test`, `eta_js_stream`.
- **must-fix** — Dependency column is wrong/incomplete: `eta_stream` also pulls `eio`; `eta_http` also pulls `yojson`, `base64`, `conf-pkg-config`; `eta_ai` also pulls `eta_redacted`; `eta_ai_openai` also pulls `eta_http_eio`, `eio`, `base64`; `eta_par` is not dep-free.
- **should-fix** — Lacks Sage "why/limits/tradeoffs" beyond the table.

## docs/background-work.md

- **must-fix** — References `Effect.Private.daemon`, which does not exist in public `effect.mli`; the public API is `Effect.daemon`.

## docs/services.md

- **must-fix** — Example uses `Runtime.create` under `open Eta`; must be `Eta_eio.Runtime.create`.

## docs/tutorial-eta-otel.md

- **must-fix** — Example uses `open Eta` + `Runtime.create`; must be `Eta_eio.Runtime.create`.
- **should-fix** — Does not state that `eta_otel` is optional and that a plain `eta` runtime has noop observability.

## docs/tutorial-eta-ai.md

- **should-fix** — Uses hyphenated package names in prose (`eta-ai-openai`, etc.) while opam/dune use underscores (`eta_ai_openai`).

## docs/http-server-production-readiness-audit.md vs lib/http/README.md

- **must-fix** — Direct contradiction. Audit says HTTP/1.1 server, TLS server, HTTPS ALPN, WebSocket server are missing and Eta is not production-ready. `lib/http/README.md` claims the server is "usable directly on the public Internet for general-purpose HTTP/1.1, h2c, and HTTPS H1/H2 service."
- **should-fix** — `lib/http/README.md` lists `Eta_http_eio` in the `eta_http` API TOC, but it is a separate package.

## lib/otel/README.md

- **must-fix** — `opam install eta-otel` is wrong; the package is `eta_otel`.
- **must-fix** — Example uses `open Eta` + `Runtime.create`; must be `Eta_eio.Runtime.create`.

## lib/par/README.md

- **should-fix** — API snippet omits `Eta_par.Island.Pool` (`create`/`shutdown`) and `Eta_par.Island.Make` referenced in prose.

## lib/stream/README.md

- **should-fix** — Quick-start does not show the required `Eta_eio.Runtime.run` to execute `program`.

## lib/schema_test/README.md, lib/ai/README.md

- **should-fix** — Too terse for Sage: no why/limits/tradeoffs, no runnable example.

## lib/eta/*.mli

- **should-fix** — No top-level `eta.mli`; every `lib/eta/` module is public. README/AGENTS.md present only a subset as core, so users cannot tell stable API from internal modules.
- **should-fix** — High-footgun combinators in `Effect` (`race`, `par`, `for_each_par`, `uninterruptible`, `daemon`, `with_background`) would benefit from one-line examples.

## Cross-cutting themes

1. `Eta_eio.Runtime.create` is the correct Eio constructor, but README and several tutorials/examples show `open Eta` + `Runtime.create`.
2. Package boundaries are inconsistently drawn (Redacted, eta_http_eio, Eta.Par).
3. HTTP server readiness claims conflict between the audit and `lib/http/README.md`.
4. Sage coverage is strong in some docs (`services.md`, `concurrency-guide.md`, `zio-boundaries.md`, `lib/sql/README.md`) and missing in others (`packages.md`, `lib/schema_test/README.md`, `lib/ai/README.md`).
