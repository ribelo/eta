# H-Ops1 Version Pin Policy

Date: 2026-05-24

## Policy

Use exact pins when the package is security-sensitive, known to be affected by
OxCaml compatibility, or part of the compiler/toolchain substrate. Use ranges
when the package is a leaf utility with stable APIs and the test matrix can
catch breakage.

## Direct Dependencies

| Dependency | Current policy | Rationale |
| --- | --- | --- |
| ocaml | exact `= 5.2.0` | The repository targets the pinned OxCaml compiler line. |
| ocaml-variants | exact `= 5.2.0+ox` | Prevents accidentally solving against mainline OCaml. |
| dune | range `>= 3.21` / generated `>= 3.0` | Dune is stable enough for a lower bound; Nix pins the actual shell version. |
| eta | repo-local library | Built from the same checkout as eta-http. |
| eta.stream | repo-local library | Built from the same checkout as eta-http. |
| eio | range `>= 1.0` | Public Eio APIs used here are stable, and the OxCaml switch pins the actual package. |
| eio_main | range `>= 1.0` | Same as Eio. |
| cstruct | unpinned | Buffer API is mature; build/test failures catch incompatible changes. |
| h2 | range `>= 0.12.0` | Allows current 0.13.x HTTP/2 fixes while preserving the ocaml-h2 API shape eta-http uses. |
| tls | exact `= 0.17.5` | Security-sensitive and currently constrained by the OxCaml-compatible branch. Known advisory exception. |
| tls-eio | exact `= 0.17.5` | Must track the exact `tls` package version. |
| x509 | exact `= 0.16.5` | Certificate validation stack should move deliberately with TLS. |
| ca-certs | exact `= 0.2.3` | Trust-root behavior should move deliberately with TLS/X.509. |
| mirage-crypto | exact `= 0.11.3` | Crypto substrate should move deliberately with TLS/X.509. |
| mirage-crypto-rng | exact `= 0.11.3` | RNG substrate should move with mirage-crypto. |
| mirage-crypto-rng-eio | exact `= 0.11.3` | RNG/Eio adapter should move with mirage-crypto-rng. |
| eqaf | unpinned | Small constant-time helper; resolved version remains audited through the closure table. |
| domain-name | unpinned | Hostname parser is mature; resolved version remains audited through the closure table. |
| ipaddr | unpinned | IP parser is mature; resolved version remains audited through the closure table. |
| bigstringaf | unpinned | Shared buffer substrate; h2/Eio constraints select compatible versions. |
| decompress | exact `= 1.5.3` | Compression codec is input-facing and should move deliberately. |
| eta.test | with-test repo-local library | Test-only local helper. |
| alcotest | with-test unpinned | Test-only runner. |
| odoc | with-doc unpinned | Documentation-only tool. |

## Required Follow-up

The TLS exact pin is defensive but not sufficient. The current `tls.0.17.5`
pin carries OSEC advisories, so the next dependency work should test the
`tls >= 2.1.0` line against the OxCaml switch or isolate an alternate TLS
substrate.
