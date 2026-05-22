(lang dune 3.21)

(generate_opam_files true)

(name eta)

(package
 (name eta)
 (synopsis "Typed functional effects for OCaml, backed by Eio")
 (description
  "Eta ports the core ideas of TypeScript Effect and Scala ZIO to idiomatic OCaml: typed failures, success values, resource scopes, schedules, retry, race, timeout, and detached fibers.")
 (depends
  (ocaml (= 5.2.0+ox))
  (dune (>= 3.0))
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
  (ocaml (= 5.2.0+ox))
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
  (ocaml (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))))

(package
 (name eta-otel)
 (synopsis "OTLP/JSON exporter for Eta's tracer capability")
 (description
  "Implements Eta's Capabilities.tracer trait against the OpenTelemetry OTLP/JSON over HTTP/1.1 protocol. No protobuf, no TLS stack, no ambient-context: just Eio TCP, a hand-written JSON encoder, and the same fiber-local span context Eta's runtime already uses.")
 (depends
  (ocaml (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (eta-stream (= :version))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (yojson (>= 2.0))
  (alcotest :with-test)))

(package
 (name ppx_eta)
 (synopsis "PPX rewriter for Eta span sugar")
 (description "Provides [%eta.fn body] sugar for Eta.fn __POS__ __FUNCTION__ body.")
 (depends
  (ocaml (= 5.2.0+ox))
  (dune (>= 3.0))
  (eta (= :version))
  (ppxlib (>= 0.30))
  (eio_main :with-test)
  (alcotest :with-test)))
