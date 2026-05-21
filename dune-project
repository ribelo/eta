(lang dune 3.21)

(generate_opam_files true)

(name effet)

(package
 (name effet)
 (synopsis "Typed functional effects for OCaml, backed by Eio")
 (description
  "Effet ports the core ideas of TypeScript Effect and Scala ZIO to idiomatic OCaml: an environment channel, a typed failure channel, a success channel, resource scopes, schedules, retry, race, timeout, and detached fibers.")
 (depends
  (ocaml (= 5.2.0+ox))
  (dune (>= 3.0))
  (eio (>= 1.0))
  portable
  (eio_main (>= 1.0))
  (alcotest :with-test)))

(package
 (name effet-stream)
 (synopsis "Typed chunked streams for Effet")
 (description
  "Adds pull-based, chunked Stream and fold-based Sink abstractions on top of Effet's typed effect runtime.")
 (depends
  (ocaml (= 5.2.0+ox))
  (dune (>= 3.0))
  (effet (= :version))
  (cstruct (>= 6.0.0))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (alcotest :with-test)))

(package
 (name effet-schema)
 (synopsis "Pure schemas and Effet-shaped decode policies")
 (description
  "Adds an idiomatic OCaml schema, decode, validation, JSON Schema, and nominal-type contract layer for Effet applications migrating from Effect Schema.")
 (depends
  (ocaml (= 5.2.0+ox))
  (dune (>= 3.0))
  (effet (= :version))))

(package
 (name effet-otel)
 (synopsis "OTLP/JSON exporter for Effet's tracer capability")
 (description
  "Implements Effet's Capabilities.tracer trait against the OpenTelemetry OTLP/JSON over HTTP/1.1 protocol. No protobuf, no TLS stack, no ambient-context: just Eio TCP, a hand-written JSON encoder, and the same fiber-local span context Effet's runtime already uses.")
 (depends
  (ocaml (= 5.2.0+ox))
  (dune (>= 3.0))
  (effet (= :version))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (yojson (>= 2.0))
  (alcotest :with-test)))

(package
 (name ppx_effet)
 (synopsis "PPX rewriter for Effet span sugar")
 (description "Provides [%effet.fn body] sugar for Effet.fn __POS__ __FUNCTION__ body.")
 (depends
  (ocaml (= 5.2.0+ox))
  (dune (>= 3.0))
  (effet (= :version))
  (ppxlib (>= 0.30))
  (eio_main :with-test)
  (alcotest :with-test)))
