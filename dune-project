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
  (eio_main (>= 1.0))
  (cstruct (>= 6.0.0))
  (yojson (>= 2.0))
  (h2 (>= 0.12.0))
  (hpack (>= 0.12.0))
  (faraday (>= 0.8.0))
  (angstrom (>= 0.16.0))
  domain-name
  ipaddr
  bigstringaf
  (decompress (= 1.5.3))
  conf-sqlite3
  ppxlib
  (alcotest :with-test)))

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
  (eio_main :with-test)
  (alcotest :with-test)))
