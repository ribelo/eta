# H-Ops1 Closure Table

Date: 2026-05-24
Switch: `5.2.0+ox`

Scope: eta-http library dependencies plus the external transitive runtime/build
packages pulled by the HTTP/2, TLS/X.509, compression, and Eio stacks in the
current Linux OxCaml switch. Local libraries `eta`, `eta.stream`, and
`eta.http` are listed as repo-local because this worktree currently publishes
them through the generated root `eta.opam` package metadata.

Command:

```sh
nix develop -c opam list --installed --columns=name,version,license: \
  ocaml ocaml-variants dune dune-configurator eta \
  eio eio_main eio_linux eio_posix bigstringaf cstruct lwt-dllist \
  optint psq fmt hmap domain-local-await mtime uring iomux h2 hpack \
  httpun-types base64 angstrom faraday tls tls-eio x509 ca-certs \
  mirage-crypto mirage-crypto-pk mirage-crypto-ec mirage-crypto-rng \
  mirage-crypto-rng-eio eqaf domain-name ipaddr macaddr logs ohex \
  hkdf pbkdf ptime asn1-combinators gmap astring bos fpath duration \
  decompress cmdliner checkseum alcotest odoc-parser
```

## Direct eta-http Declarations

| Package | Constraint in root dune-project / eta.opam | Role |
| --- | --- | --- |
| ocaml | = 5.2.0 | compiler |
| ocaml-variants | = 5.2.0+ox | OxCaml compiler variant |
| dune | >= 3.21 and >= 3.0 | build system |
| eta | repo-local library | effect runtime |
| eta.stream | repo-local library | streams |
| eio | >= 1.0 | IO/concurrency substrate |
| eio_main | >= 1.0 | Eio runtime entry |
| cstruct | unpinned | Eio/TLS byte buffers |
| h2 | >= 0.12.0 | HTTP/2 and HPACK substrate |
| tls | = 0.17.5 | TLS substrate |
| tls-eio | = 0.17.5 | TLS/Eio adapter |
| x509 | = 0.16.5 | certificate validation |
| ca-certs | = 0.2.3 | system trust roots |
| mirage-crypto | = 0.11.3 | crypto substrate |
| mirage-crypto-rng | = 0.11.3 | RNG substrate |
| mirage-crypto-rng-eio | = 0.11.3 | RNG/Eio adapter |
| eqaf | unpinned | constant-time helpers |
| domain-name | unpinned | SNI/host parsing |
| ipaddr | unpinned | IP literal parsing |
| bigstringaf | unpinned | h2/compression buffers |
| decompress | = 1.5.3 | gzip encode/decode |
| eta-test | with-test | repo-local tests |
| alcotest | with-test | test runner |
| odoc | with-doc | documentation |

## Observed External Closure

| Package | Version | License | Source path |
| --- | --- | --- | --- |
| alcotest | 1.9.0+ox | ISC | test only |
| angstrom | 0.16.1 | BSD-3-clause | h2/hpack |
| asn1-combinators | 0.2.6 | ISC | x509 |
| astring | 0.8.5 | ISC | ca-certs |
| base64 | 3.5.2 | ISC | h2/x509 |
| bigstringaf | 0.9.0 | BSD-3-clause | direct, h2, eio |
| bos | 0.3.0 | ISC | ca-certs |
| ca-certs | 0.2.3 | ISC | direct |
| checkseum | 0.5.3 | MIT | decompress |
| cmdliner | 2.1.1 | ISC | decompress |
| cstruct | 6.2.0 | ISC | direct, TLS, Eio |
| decompress | 1.5.3 | MIT | direct |
| domain-local-await | 1.0.1 | ISC | eio |
| domain-name | 0.5.0 | ISC | direct, TLS/X.509 |
| dune | 3.22.2+ox | MIT | build |
| dune-configurator | 3.21.0+ox | MIT | mirage-crypto |
| duration | 0.3.1 | ISC | mirage-crypto-rng |
| eio | 1.3+ox | ISC | direct |
| eio_linux | 1.3+ox | ISC | eio_main on Linux |
| eio_main | 1.3+ox | ISC | direct |
| eio_posix | 1.3+ox | ISC | eio_main |
| eqaf | 0.9 | MIT | direct, mirage-crypto |
| faraday | 0.8.2 | BSD-3-clause | h2/hpack |
| fmt | 0.11.0 | ISC | eio/TLS/X.509 |
| fpath | 0.7.3 | ISC | ca-certs |
| gmap | 0.3.0 | ISC | x509 |
| h2 | 0.13.0 | BSD-3-clause | direct |
| hkdf | 1.0.4 | BSD-2-Clause | tls |
| hmap | 0.8.1 | ISC | eio |
| hpack | 0.13.0 | BSD-3-clause | h2 |
| httpun-types | 0.2.0 | BSD-3-clause | h2 |
| iomux | 0.4 | ISC | eio_posix |
| ipaddr | 5.6.2 | ISC | direct, TLS/X.509 |
| logs | 0.10.0 | ISC | TLS/X.509/RNG |
| lwt-dllist | 1.1.0 | MIT | eio |
| macaddr | 5.6.2 | ISC | ipaddr package family |
| mirage-crypto | 0.11.3 | ISC | direct |
| mirage-crypto-ec | 0.11.3 | MIT | tls/x509 |
| mirage-crypto-pk | 0.11.3 | ISC | tls/x509 |
| mirage-crypto-rng | 0.11.3 | ISC | direct |
| mirage-crypto-rng-eio | 0.11.3 | ISC | direct |
| mtime | 2.1.0 | ISC | eio/RNG |
| ocaml | 5.2.0 | LGPL-2.1-or-later WITH OCaml-LGPL-linking-exception | compiler |
| ocaml-variants | 5.2.0+ox | LGPL-2.1-or-later WITH OCaml-LGPL-linking-exception | compiler |
| odoc-parser | 3.2.1 | ISC | doc tooling in switch |
| ohex | 0.2.0 | BSD-2-Clause | TLS family tooling |
| optint | 0.3.0 | ISC | eio/decompress |
| pbkdf | 1.2.0 | BSD-2-Clause | x509 |
| psq | 0.2.1 | ISC | h2/eio |
| ptime | 1.2.0 | ISC | tls-eio/x509/ca-certs |
| tls | 0.17.5 | BSD-2-Clause | direct |
| tls-eio | 0.17.5 | BSD-2-Clause | direct |
| uring | 2.7.0 | ISC and MIT | eio_linux |
| x509 | 0.16.5 | BSD-2-Clause | direct |

## Repo-Local Packages

| Package | Version | License metadata | Notes |
| --- | --- | --- | --- |
| eta | repo version | generated root `eta.opam` lacks license metadata | effect runtime library |
| eta.stream | repo version | generated root `eta.opam` lacks license metadata | stream library |
| eta.http | repo version | generated root `eta.opam` lacks license metadata | HTTP client library under audit |

The repo-local libraries are the only license metadata gap observed in this
audit. Full `opam lint *.opam` still reports missing maintainer/authors,
homepage, bug-reports, and license fields for generated `eta.opam`.
