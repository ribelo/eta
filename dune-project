(lang dune 3.21)

(generate_opam_files true)

(name effet)

(package
 (name effet)
 (synopsis "Typed functional effects for OCaml, backed by Eio")
 (description
  "Effet ports the core ideas of TypeScript Effect and Scala ZIO to idiomatic OCaml: an environment channel, a typed failure channel, a success channel, resource scopes, schedules, retry, race, timeout, and detached fibers.")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.0))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (alcotest :with-test)))

(package
 (name effet-otel)
 (synopsis "OTLP/JSON exporter for Effet's tracer capability")
 (description
  "Implements Effet's Capabilities.tracer trait against the OpenTelemetry OTLP/JSON over HTTP/1.1 protocol. No protobuf, no TLS stack, no ambient-context: just Eio TCP, a hand-written JSON encoder, and the same fiber-local span context Effet's runtime already uses.")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.0))
  (effet (= :version))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (alcotest :with-test)))

