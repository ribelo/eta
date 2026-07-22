(lang dune 3.21)
(generate_opam_files true)

(name eta)
(authors "Rafal Krzywaznia")
(maintainers "Rafal Krzywaznia <r.krzywaznia@gmail.com>")
(license MIT)
(homepage "https://github.com/ribelo/eta")
(bug_reports "https://github.com/ribelo/eta/issues")

(package
 (name eta)
 (synopsis "Typed functional effects for OCaml")
 (description
  "Eta ports the core ideas of TypeScript Effect and Scala ZIO to idiomatic OCaml: typed failures, success values, resource scopes, schedules, retry, race, timeout, and detached fibers.")
 (depends
  (ocaml (>= 5.2.0))))

(package
 (name eta_cache)
 (synopsis "Effect-integrated keyed cache for Eta")
 (description
  "eta_cache provides a bounded keyed cache with Eta single-flight lookup sharing, per-result TTL, typed-failure caching, lazy expiry, invalidation, refresh, and stats.")
 (depends
  (ocaml (>= 5.2.0))
  eta))

(package
 (name eta_signal)
 (synopsis "Incremental-style reactive signals for Eta")
 (description
  "eta_signal provides an optional explicit-stabilization reactive graph for Eta programs.")
 (depends
  (ocaml (>= 5.2.0))
  (dune (>= 3.0))
  eta
  eta_stream))

(package
 (name eta_js)
 (allow_empty)
 (synopsis "Js_of_ocaml Eta facade")
 (description
  "eta_js provides a js_of_ocaml-first Eta facade backed by the eta_jsoo runtime host.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_jsoo
  (js_of_ocaml (>= 5.0))))

(package
 (name eta_jsoo)
 (allow_empty)
 (synopsis "Js_of_ocaml-native runtime backend for Eta")
 (description
  "eta_jsoo implements Eta's runtime contract directly on JavaScript timers and microtasks for js_of_ocaml targets.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  (js_of_ocaml (>= 5.0))))

(package
 (name eta_js_test)
 (allow_empty)
 (synopsis "Testing helpers for eta_js")
 (description
  "eta_js_test provides js_of_ocaml Node test helpers for eta_js.")
 (depends
  (ocaml (>= 5.2.0))
  eta_js
  (js_of_ocaml (>= 5.0))))

(package
 (name eta_js_stream)
 (allow_empty)
 (synopsis "JavaScript streams for eta_js")
 (description
  "eta_js_stream provides pull-based streams for eta_js without Eio or Cstruct dependencies.")
 (depends
  (ocaml (>= 5.2.0))
  eta_js))

(package
 (name eta_eio)
 (synopsis "Eio runtime backend for Eta")
 (description
  "eta_eio provides the Eio-backed runtime constructor and host bridges for Eta programs.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_blocking
  (eio (>= 1.0))
  (cstruct (>= 6.0.0))))

(package
 (name eta_blocking)
 (synopsis "Native blocking worker pools for Eta")
 (description
  "eta_blocking provides bounded blocking worker-pool helpers for Eta native runtime packages and synchronous connector bindings.")
 (depends
  (ocaml (>= 5.2.0))
  eta))

(package
 (name eta_linux_input)
 (synopsis "Linux evdev and uinput primitives for Eta applications")
 (description
  "eta_linux_input provides reusable Linux evdev input-device metadata, event reading, exclusive grabs, and uinput virtual-device helpers for Eta applications.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_blocking))

(package
 (name eta_par)
 (synopsis "Native heartbeat-backed parallel runtime for Eta")
 (description
  "eta_par provides Eta's native worker-domain fork-join scheduler and island offload helpers as an optional package.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_blocking))

(package
 (name eta_utop)
 (synopsis "UTop convenience helpers for Eta effects")
 (description
  "eta_utop provides small Eio-backed helpers for running Eta effects from dune utop sessions.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_blocking
  eta_eio
  eio_main))

(package
 (name eta_stream)
 (synopsis "Streams, channels, mailboxes, and bounded queues for Eta")
 (description
  "eta_stream provides stream and queue primitives for Eta programs.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  (eio (>= 1.0))
  (cstruct (>= 6.0.0))))

(package
 (name eta_http_h2)
 (synopsis "HTTP/2 protocol implementation for Eta")
 (description
  "eta_http_h2 provides an H2O-inspired HTTP/2 frame, settings, stream, and connection state machine for Eta.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_http
  (bigstringaf (>= 0.9.0))
  (cstruct (>= 6.0.0))
  (angstrom (>= 0.16.0))
  (faraday (>= 0.8.0))))

(package
 (name eta_http_h1)
 (synopsis "HTTP/1 protocol helpers for Eta HTTP")
 (description
  "eta_http_h1 provides HTTP/1 request and response parser/writer helpers for eta-http adapters and protocol tests.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_http))

(package
 (name eta_http_tls_openssl)
 (synopsis "OpenSSL TLS state-machine bindings for Eta HTTP")
 (description
  "eta_http_tls_openssl provides native OpenSSL memory-BIO state machines, sessions, CA loading, and concrete TLS context creation for Eta HTTP adapters.")
 (depends
  (ocaml (>= 5.2.0))
  (cstruct (>= 6.0.0))
  conf-pkg-config
  conf-openssl))

(package
 (name eta_http_ws)
 (synopsis "WebSocket codec and handshake helpers for Eta HTTP")
 (description
  "eta_http_ws provides RFC 6455 frame codecs and backend-neutral handshake helpers.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  base64))

(package
 (name eta_http)
 (synopsis "Backend-neutral HTTP protocol and client contract for Eta")
 (description
  "eta_http provides the shared HTTP request/response model, runtime client contract, typed errors, retry handling, body streams, and pure protocol helpers.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  (yojson (>= 2.0))
  (crowbar :with-test)
  domain-name
  ipaddr
  bigstringaf
  (decompress (= 1.5.3))))

(package
 (name eta_http_js)
 (allow_empty)
 (synopsis "Js_of_ocaml Fetch client adapter for eta-http")
 (description
  "eta_http_js provides a js_of_ocaml Fetch-backed HTTP client adapter for Eta HTTP.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_http
  eta_jsoo
  (js_of_ocaml (>= 5.0))))

(package
 (name eta_http_eio)
 (synopsis "Eio transport adapter for eta-http")
 (description
  "eta_http_eio provides Eio-backed HTTP/1.1, HTTP/2, TLS, and WebSocket transport adapters for eta-http.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_blocking
  eta_eio
  eta_http
  eta_http_h1
  eta_http_h2
  eta_http_tls_openssl
  eta_http_ws
  eta_stream
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (cstruct (>= 6.0.0))
  (faraday (>= 0.8.0))
  (angstrom (>= 0.16.0))
  (yojson (>= 2.0))
  domain-name
  ipaddr
  bigstringaf))

(package
 (name eta_http_service)
 (synopsis "Composable HTTP service helpers for Eta")
 (description
  "eta_http_service provides small routing, extractor, JSON response, and middleware helpers over Eta_http.Server.handler.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_http
  eta_router
  (yojson (>= 2.0))))

(package
 (name eta_http_service_eio)
 (synopsis "Eio serving helpers for eta-http-service")
 (description
  "eta_http_service_eio provides readiness and graceful-drain serving helpers over eta_http_eio.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_http
  eta_http_eio
  eta_http_service
  (eio (>= 1.0))))

(package
 (name eta_sql_dsl)
 (synopsis "Shared SQL DSL for Eta connectors")
 (description
  "eta_sql_dsl provides the backend-agnostic typed SQL builder shared by Eta SQL connector packages.")
 (depends
  (ocaml (>= 5.2.0))))

(package
 (name eta_sql_driver)
 (synopsis "Shared Eta SQL driver runtime helpers")
 (description
  "eta_sql_driver provides shared blocking-pool and cancellation helpers for Eta SQL connector packages.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_blocking))

(package
 (name eta_sql)
 (synopsis "SQLite client for Eta")
 (description
  "eta_sql provides prepared SQLite statements and a typed Eta effect surface.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_blocking
  eta_sql_driver
  eta_sql_dsl
  conf-pkg-config
  conf-sqlite3))

(package
 (name eta_duckdb)
 (synopsis "DuckDB connector for Eta")
 (description
  "eta_duckdb provides an optional DuckDB connector for Eta programs. The DuckDB C library is loaded at runtime by the connector package, not by root eta.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_blocking
  eta_sql_driver
  eta_sql_dsl))

(package
 (name eta_turso)
 (synopsis "Turso connector for Eta")
 (description
  "eta_turso provides an optional Turso SQL connector for Eta programs. The Turso SQLite-compatible C library is loaded at runtime by the connector package, not by root eta.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_blocking
  eta_sql_driver
  eta_sql
  eta_sql_dsl))

(package
 (name eta_ladybug)
 (synopsis "LadybugDB graph connector for Eta")
 (description
  "eta_ladybug provides an optional LadybugDB graph connector for Eta programs. The LadybugDB C library is loaded at runtime by the connector package, not by root eta.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_blocking))

(package
 (name eta_redacted)
 (synopsis "Secret-wrapping types that hide values from logs and traces")
 (description
  "eta_redacted provides small secret wrappers for Eta logs, traces, and provider clients.")
 (depends
  (ocaml (>= 5.2.0))))

(package
 (name eta_router)
 (synopsis "High-performance zero-copy URL path router")
 (description
  "eta_router provides a radix-trie URL path router with named and catch-all parameters, designed for low allocation and idiomatic OxCaml code.")
 (depends
  (ocaml (>= 5.2.0))))

(package
 (name eta_schema)
 (synopsis "Schema definitions and JSON codecs for Eta")
 (description
  "eta_schema provides lightweight schema definitions for Eta programs.")
 (depends
  (ocaml (>= 5.2.0))
  eta))

(package
 (name eta_test)
 (synopsis "Testing helpers for Eta")
 (description
  "eta_test provides virtual clocks, deterministic random values, and Alcotest helpers for Eta programs.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_blocking
  eta_eio
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  alcotest))

(package
 (name eta_schema_test)
 (synopsis "Alcotest helpers for eta_schema tests")
 (description
  "eta_schema_test provides test helpers for eta_schema codecs and values.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_schema
  alcotest))

(package
 (name eta_otel)
 (synopsis "OpenTelemetry exporter for Eta")
 (description
  "eta_otel exports Eta logger, tracer, and meter capabilities through OpenTelemetry protocols.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_stream
  eta_http
  (mtime (>= 2.0))
  (yojson (>= 2.0))))

(package
 (name eta_ai)
 (synopsis "LLM client core for Eta")
 (description
  "eta_ai provides provider-agnostic chat and streaming types for Eta LLM clients.")
 (depends
  (ocaml (>= 5.2.0))
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
  (ocaml (>= 5.2.0))
  eta_ai
  base64))

(package
 (name eta_ai_openai)
 (synopsis "OpenAI provider for Eta AI")
 (description
  "eta_ai_openai provides transport-neutral OpenAI chat, responses, embeddings, media, transcription, and realtime codec helpers for Eta.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_ai
  eta_ai_openai_codec
  eta_redacted
  eta_http
  base64
  (yojson (>= 2.0))))

(package
 (name eta_ai_openai_realtime_eio)
 (synopsis "Eio WebSocket transport for OpenAI Realtime")
 (description
  "eta_ai_openai_realtime_eio provides the native Eio WebSocket connection adapter for OpenAI Realtime over eta_http_eio.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_ai
  eta_ai_openai
  eta_http
  eta_http_eio
  eta_redacted
  eta_stream
  (eio (>= 1.0))))

(package
 (name eta_ai_anthropic)
 (synopsis "Anthropic provider for Eta AI")
 (description
  "eta_ai_anthropic provides Anthropic chat and streaming clients for Eta.")
 (depends
  (ocaml (>= 5.2.0))
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
  (ocaml (>= 5.2.0))
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
  (ocaml (>= 5.2.0))
  eta
  eta_ai
  eta_ai_openai_codec
  eta_redacted
  eta_http
  base64
  (yojson (>= 2.0))))


(package
 (name eta_ai_openai_codex)
 (synopsis "OpenAI Codex Responses and ChatGPT OAuth for Eta AI")
 (description
  "eta_ai_openai_codex provides Codex Responses transport, ChatGPT OAuth PKCE credential types, and provider-owned headers for Eta.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_ai
  eta_ai_openai_codec
  eta_redacted
  eta_http
  base64
  (yojson (>= 2.0))))

(package
 (name eta_ai_moonshot)
 (synopsis "Moonshot Open Platform provider for Eta AI")
 (description
  "eta_ai_moonshot provides Kimi-native Chat Completions, API-key credentials, and native model catalog helpers for Moonshot Open Platform.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_ai
  eta_ai_openai_codec
  eta_ai_openai_compat
  eta_redacted
  eta_http
  (yojson (>= 2.0))))

(package
 (name eta_ai_kimi_coding)
 (synopsis "Kimi Coding provider for Eta AI")
 (description
  "eta_ai_kimi_coding provides Kimi-native Chat Completions, Anthropic-compatible Messages routing, device-code OAuth, API-key credentials, provider headers, and catalog metadata including protocol declaration.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_ai
  eta_ai_openai_codec
  eta_ai_openai_compat
  eta_ai_anthropic
  eta_redacted
  eta_http
  (yojson (>= 2.0))))

(package
 (name eta_exa)
 (synopsis "Exa HTTP client for Eta")
 (description
  "eta_exa provides typed request planning and raw-response execution for Exa search, contents, code-context, and agent-run APIs.")
 (depends
  (ocaml (>= 5.2.0))
  eta
  eta_http
  eta_redacted))

(package
 (name ppx_eta)
 (synopsis "PPX syntax helpers for Eta")
 (description
  "ppx_eta provides Eta effect syntax helpers, typed-error printers, and Eta SQL table declarations.")
 (depends
  (ocaml (>= 5.2.0))
  ppxlib
  (eta :with-test)
  (eta_sql :with-test)
  (eio_main :with-test)
  (alcotest :with-test)))
