# Endpoint S gates

All required commands passed on the uncommitted Endpoint-S tree before its
endpoint commit.

| Command | Status |
| --- | ---: |
| `nix develop -c dune build @install` | 0 |
| `nix develop -c dune runtest --force` | 0 |
| `nix develop -c eta-oxcaml-test-shipped` | 0 |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo test/signal_jsoo test/http_js` | 0 |

Each `.status` file records the exact command, UTC start, and exit status. The
required dedicated `_build-mainline` directory was used.

Additional focused development gate:

```text
nix develop -c dune runtest test/core_common test/test test/blocking_common test/effect_introspection --force
exit_status=0
```

The former `blocking_common` footprint assertion was migrated to the ordinary
behavior test `run executes blocking function`.
