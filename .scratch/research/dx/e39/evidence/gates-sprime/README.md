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

## Follow-up 2 final rerun

After restoring the safe benchmark fingerprint and adding the side-effectful
`Map` witness, every requested check passed again:

| Command | Status | Record |
| --- | ---: | --- |
| `nix develop -c dune build @install` | 0 | `build-install-final.status` |
| `nix develop -c dune runtest --force` | 0 | `runtest-final.status` |
| `nix develop -c eta-oxcaml-test-shipped` | 0 | `shipped-final.status` |
| `nix develop -c dune runtest test/effect_introspection --force` | 0 | `focused-final.status` |
| mainline JS targets with dedicated `_build-mainline` | 0 | `mainline-js-final.status` |

The directly affected filtered workflow also passed without traversing the
deep blueprint: `benchmark-filter-final.status` records
`effect_construction.exe --quick --filter 'effect.construction.map_bind$'`
returning `construction_sink=0` with exit status 0.
