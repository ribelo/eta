(lang dune 3.21)

(generate_opam_files true)

(name eta)

(package
 (name eta)
 (synopsis "Typed functional effects for OCaml, backed by Eio")
 (description
  "Eta ports the core ideas of TypeScript Effect and Scala ZIO to idiomatic OCaml: typed failures, success values, resource scopes, schedules, retry, race, timeout, and detached fibers.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eio (>= 1.0))
  portable
  (cstruct (>= 6.0.0))))

(package
 (name eta_utop)
 (synopsis "UTop convenience helpers for Eta effects")
 (description
  "eta_utop provides small Eio_main-backed helpers for running Eta effects from dune utop sessions.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  (eio (>= 1.0))
  eio_main))

(package
 (name eta_stream)
 (synopsis "Streams, channels, mailboxes, and bounded queues for Eta")
 (description
  "eta_stream provides stream and queue primitives for Eta programs.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  (eio (>= 1.0))
  (cstruct (>= 6.0.0))))

(package
 (name eta_http)
 (synopsis "HTTP/1.1, HTTP/2, WebSockets and TLS client and server for Eta")
 (description
  "eta_http provides HTTP, WebSocket, TLS, and HTTP/2 support for Eta programs.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  eta_stream
  (eio (>= 1.0))
  (cstruct (>= 6.0.0))
  (h2 (>= 0.12.0))
  (hpack (>= 0.12.0))
  (faraday (>= 0.8.0))
  (angstrom (>= 0.16.0))
  (crowbar :with-test)
  domain-name
  ipaddr
  bigstringaf
  base64
  (decompress (= 1.5.3))
  conf-pkg-config
  conf-openssl))

(package
 (name eta_sql_dsl)
 (synopsis "Shared SQL DSL for Eta connectors")
 (description
  "eta_sql_dsl provides the backend-agnostic typed SQL builder shared by Eta SQL connector packages.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))))

(package
 (name eta_sql)
 (synopsis "SQLite client for Eta")
 (description
  "eta_sql provides prepared SQLite statements and a typed Eta effect surface.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  (eio (>= 1.0))
  conf-pkg-config
  conf-sqlite3))

(package
 (name eta_duckdb)
 (synopsis "DuckDB connector for Eta")
 (description
  "eta_duckdb provides an optional DuckDB connector for Eta programs. The DuckDB C library is loaded at runtime by the connector package, not by root eta.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  eta_sql_dsl))

(package
 (name eta_turso)
 (synopsis "Turso connector for Eta")
 (description
  "eta_turso provides an optional Turso SQL connector for Eta programs. The Turso SQLite-compatible C library is loaded at runtime by the connector package, not by root eta.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  eta_sql
  eta_sql_dsl))

(package
 (name eta_ladybug)
 (synopsis "LadybugDB graph connector for Eta")
 (description
  "eta_ladybug provides an optional LadybugDB graph connector for Eta programs. The LadybugDB C library is loaded at runtime by the connector package, not by root eta.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta))

(package
 (name eta_redacted)
 (synopsis "Secret-wrapping types that hide values from logs and traces")
 (description
  "eta_redacted provides small secret wrappers for Eta logs, traces, and provider clients.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))))

(package
 (name eta_schema)
 (synopsis "Schema definitions and JSON codecs for Eta")
 (description
  "eta_schema provides lightweight schema definitions for Eta programs.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta))

(package
 (name eta_test)
 (synopsis "Testing helpers for Eta")
 (description
  "eta_test provides virtual clocks, deterministic random values, and Alcotest helpers for Eta programs.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  alcotest))

(package
 (name eta_schema_test)
 (synopsis "Alcotest helpers for eta_schema tests")
 (description
  "eta_schema_test provides test helpers for eta_schema codecs and values.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  eta_schema
  eta_test
  alcotest))

(package
 (name eta_otel)
 (synopsis "OpenTelemetry exporter for Eta")
 (description
  "eta_otel exports Eta logger, tracer, and meter capabilities through OpenTelemetry protocols.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  eta_stream
  eta_http
  (eio (>= 1.0))
  (yojson (>= 2.0))))

(package
 (name eta_ai)
 (synopsis "LLM client core for Eta")
 (description
  "eta_ai provides provider-agnostic chat and streaming types for Eta LLM clients.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  eta_redacted
  eta_http
  (yojson (>= 2.0))))

(package
 (name eta_ai_openai_codec)
 (synopsis "OpenAI wire codecs for Eta AI providers")
 (description
  "eta_ai_openai_codec provides shared OpenAI-compatible wire codecs for Eta AI providers.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta_ai
  base64))

(package
 (name eta_ai_openai)
 (synopsis "OpenAI provider for Eta AI")
 (description
  "eta_ai_openai provides OpenAI chat, streaming, and realtime clients for Eta.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  eta_ai
  eta_ai_openai_codec
  eta_redacted
  eta_http
  eta_stream
  base64
  (yojson (>= 2.0))))

(package
 (name eta_ai_anthropic)
 (synopsis "Anthropic provider for Eta AI")
 (description
  "eta_ai_anthropic provides Anthropic chat and streaming clients for Eta.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  eta_ai
  eta_redacted
  eta_http
  (yojson (>= 2.0))))

(package
 (name eta_ai_openai_compat)
 (synopsis "OpenAI-compatible provider adapter for Eta AI")
 (description
  "eta_ai_openai_compat provides OpenAI-compatible provider adapters for Eta.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  eta_ai
  eta_ai_openai_codec
  eta_redacted
  eta_http
  (yojson (>= 2.0))))

(package
 (name eta_ai_openrouter)
 (synopsis "OpenRouter provider for Eta AI")
 (description
  "eta_ai_openrouter provides OpenRouter clients for Eta.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  eta
  eta_ai
  eta_ai_openai_codec
  eta_redacted
  eta_http
  base64
  (yojson (>= 2.0))))

(package
 (name ppx_eta)
 (synopsis "PPX syntax helpers for Eta")
 (description
  "ppx_eta provides small syntax helpers for Eta effects and Eta SQL table declarations.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  ppxlib
  (eta :with-test)
  (eta_sql :with-test)
  (eio_main :with-test)
  (alcotest :with-test)))
