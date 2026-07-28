# Required gate results — Follow-up 1

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
| `EIO_BACKEND=posix _build/default/test/core_eio/run.exe test '^Effect Eio admission$'` | PASS (3 tests) |
| `EIO_BACKEND=posix _build/default/test/laws/law_properties.exe` | PASS (77 properties) |
| `nix develop -c dune runtest test/core_eio --force` | PASS (634 tests, included by full gate) |

Focused status excerpts are in `followup-admission-output.txt` and
`followup-law-output.txt`. The broader deadlock/parity excerpts remain in
`deadlock-shared-output.txt` and `deadlock-law-output.txt`.
