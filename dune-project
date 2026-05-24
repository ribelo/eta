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
  parallel
  (eio_main (>= 1.0))
  (cstruct (>= 6.0.0))
  (yojson (>= 2.0))
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
  ppxlib
  (alcotest :with-test)))
