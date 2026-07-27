# Endpoint R gates

All required commands passed on the uncommitted Endpoint-R tree before its
endpoint commit.

| Command | Status |
| --- | ---: |
| `nix develop -c dune build @install` | 0 |
| `nix develop -c dune runtest --force` | 0 |
| `nix develop -c eta-oxcaml-test-shipped` | 0 |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo test/signal_jsoo test/http_js` | 0 |

Each `.status` file records the exact command, UTC start, and exit status. The
required dedicated `_build-mainline` directory was used.

Focused development gate:

```text
nix develop -c dune runtest test/api_dx test/core_common test/runtime_common --force
exit_status=0
```

The full native and shipped suites include the registered tracing witnesses
`named span status ok`, `span kind`, and `fn records location`.
