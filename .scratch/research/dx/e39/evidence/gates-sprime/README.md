# Endpoint S′ gates

All required commands passed on the uncommitted S′ tree before its endpoint
commit.

| Command | Status |
| --- | ---: |
| `nix develop -c dune build @install` | 0 |
| `nix develop -c dune runtest --force` | 0 |
| `nix develop -c eta-oxcaml-test-shipped` | 0 |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo test/signal_jsoo test/http_js` | 0 |

Each `.status` file records the exact command, UTC start, and exit status. The
mandatory dedicated `_build-mainline` directory was used. Full `runtest` and
shipped execution include the new Alcotest case `constructor tree is exact and
inspection does not evaluate`; full `runtest` also runs the named Dune alias
`effect-describe-snapshot` through `@runtest`.
