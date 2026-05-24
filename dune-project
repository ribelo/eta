(lang dune 3.21)

(generate_opam_files true)

(name eta)

(package
 (name eta-redacted)
 (synopsis "Redacted value wrapper for Eta packages")
 (description
  "Provides a tiny abstract wrapper for secrets and other sensitive values, with labelled redacted formatting and explicit value extraction at IO boundaries.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (alcotest :with-test)))

(package
 (name eta)
 (synopsis "Typed functional effects for OCaml, backed by Eio")
 (description
  "Eta ports the core ideas of TypeScript Effect and Scala ZIO to idiomatic OCaml: typed failures, success values, resource scopes, schedules, retry, race, timeout, and detached fibers.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta-redacted (= :version))
  (eio (>= 1.0))
  portable
  (eio_main (>= 1.0))
  (alcotest :with-test)))

(package
 (name eta-stream)
 (synopsis "Typed chunked streams for Eta")
 (description
  "Adds pull-based, chunked Stream and fold-based Sink abstractions on top of Eta's typed effect runtime.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (cstruct (>= 6.0.0))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (alcotest :with-test)))

(package
 (name eta-schema)
 (synopsis "Pure schemas and Eta-shaped decode policies")
 (description
  "Adds an idiomatic OCaml schema, decode, validation, JSON Schema, and nominal-type contract layer for Eta applications migrating from Effect Schema.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))))

(package
 (name eta-schema-test)
 (synopsis "Schema testing helpers for Eta Schema")
 (description
  "Provides Alcotest-oriented helpers for Eta Schema decode, encode, issue, and round-trip assertions.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (eta-schema (= :version))
  (eta-test (= :version))
  alcotest))

(package
 (name eta-otel)
 (synopsis "OTLP/JSON exporter for Eta's tracer capability")
 (description
  "Implements Eta's Capabilities.tracer trait against the OpenTelemetry OTLP/JSON over HTTP. No protobuf, no ambient-context: just Eta streams, eta-http transport, a hand-written JSON encoder, and the same fiber-local span context Eta's runtime already uses.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (eta-stream (= :version))
  (eta-http (= :version))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (yojson (>= 2.0))
  (alcotest :with-test)))

(package
 (name eta-ai)
 (synopsis "Core AI vocabulary for Eta provider packages")
 (description
  "Defines Eta-shaped AI message, response, tool, usage, and error vocabulary. Provider packages own provider-specific HTTP encoding and decoding.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (eta-redacted (= :version))
  (eta-http (= :version))
  (yojson (>= 2.0))
  (eio_main :with-test)
  (alcotest :with-test)))

(package
 (name eta-ai-openai-codec)
 (synopsis "Shared OpenAI-family provider codec helpers for eta-ai")
 (description
  "Provides shared JSON codec helpers for OpenAI, OpenAI-compatible, and OpenRouter eta-ai provider packages.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta-ai (= :version))))

(package
 (name eta-ai-openai)
 (synopsis "OpenAI provider package for eta-ai")
 (description
  "Constructs eta-ai provider values and eta-http request runners for OpenAI Responses API calls, explicit legacy Chat Completions compatibility, tools, structured outputs, and streaming.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (eta-ai (= :version))
  (eta-ai-openai-codec (= :version))
  (eta-redacted (= :version))
  (eta-http (= :version))
  (yojson (>= 2.0))
  (eio_main :with-test)
  (alcotest :with-test)))

(package
 (name eta-ai-anthropic)
 (synopsis "Anthropic provider package for eta-ai")
 (description
  "Constructs eta-ai provider values and eta-http request runners for Anthropic Messages API calls, tool use, streaming, and prompt caching controls.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (eta-ai (= :version))
  (eta-redacted (= :version))
  (eta-http (= :version))
  (yojson (>= 2.0))
  (eio_main :with-test)
  (alcotest :with-test)))

(package
 (name eta-ai-openai-compat)
 (synopsis "OpenAI-compatible provider package for eta-ai")
 (description
  "Constructs configurable eta-ai provider values and eta-http request runners for OpenAI-compatible chat-completions APIs.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (eta-ai (= :version))
  (eta-ai-openai-codec (= :version))
  (eta-redacted (= :version))
  (eta-http (= :version))
  (yojson (>= 2.0))
  (eio_main :with-test)
  (alcotest :with-test)))

(package
 (name eta-ai-openrouter)
 (synopsis "OpenRouter provider package for eta-ai")
 (description
  "Constructs eta-ai provider values and eta-http request runners for OpenRouter Responses API calls, routing controls, fallback chains, attribution headers, and provider errors.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (eta-ai (= :version))
  (eta-ai-openai-codec (= :version))
  (eta-redacted (= :version))
  (eta-http (= :version))
  (yojson (>= 2.0))
  (eio_main :with-test)
  (alcotest :with-test)))

(package
 (name eta-http)
 (synopsis "HTTP/1.1 and HTTP/2 client for Eta")
 (description
  "Clean-room HTTP client package for Eta. v1 owns HTTP/1.1, client lifecycle, retries, streaming bodies, and observability while using ocaml-h2 for HTTP/2 frame/HPACK handling and ocaml-tls for TLS.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (eta-stream (= :version))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  cstruct
  (h2 (>= 0.12.0))
  (tls (= 0.17.5))
  (tls-eio (= 0.17.5))
  (x509 (= 0.16.5))
  (ca-certs (= 0.2.3))
  (mirage-crypto (= 0.11.3))
  (mirage-crypto-rng (= 0.11.3))
  (mirage-crypto-rng-eio (= 0.11.3))
  eqaf
  domain-name
  ipaddr
  bigstringaf
  (decompress (= 1.5.3))
  (eta-test :with-test)
  (alcotest :with-test)))

(package
 (name eta-test)
 (synopsis "Testing helpers for Eta")
 (description
  "Provides Eta-shaped testing helpers: a virtual-time test clock, deterministic random tokens, and cause assertion helpers.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  alcotest))

(package
 (name ppx_eta)
 (synopsis "PPX rewriter for Eta span sugar")
 (description "Provides [%eta.fn body] sugar for Eta.fn __POS__ __FUNCTION__ body.")
 (depends
  (ocaml (= 5.2.0))
  (ocaml-variants (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (ppxlib (>= 0.30))
  (eio_main :with-test)
  (alcotest :with-test)))
