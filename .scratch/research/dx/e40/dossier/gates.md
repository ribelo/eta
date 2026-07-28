# Required gate results

All commands were run exactly from the E40 worktree after the final source and
test changes.

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS (exit 0) |
| `nix develop -c dune runtest --force` | PASS (exit 0) |
| `nix develop -c eta-oxcaml-test-shipped` | PASS (exit 0) |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo test/signal_jsoo test/http_js` | PASS (exit 0) |

Focused evidence also passed:

| Command | Result |
| --- | --- |
| `nix develop -c dune build lib/eta/eta.cmxa` | PASS |
| `nix develop -c dune runtest test/laws test/core_common --force` | PASS |
| `nix develop -c dune runtest test/core_eio --force` | PASS (631 tests) |
