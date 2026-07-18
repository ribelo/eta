# E5 review packet manifest

Experiment: DX-E5 — Negative compile tests and "Eta type errors, translated".
Branch: `research/dx-e4e5-cause-corpus-type-errors`.

## Contents

| File | What it is |
|---|---|
| `w5-rigged.ml` | The rigged W5 task: user-shaped code that stashes a `Supervisor` child handle in a top-level `ref` to use after the nursery. Does not compile — that is the task. (The `Warning 24 [bad-module-name]` line in `error.txt` is an artifact of the task filename, not part of the puzzle.) |
| `error.txt` | The exact compiler output for `w5-rigged.ml`, captured with the OxCaml 5.2.0+ox gate compiler. |
| `page-excerpt.md` | Entry 1 of `docs/type-errors.md` (the supervisor-escape translation), verbatim. |
| `QUESTIONS.md` | The two-phase solve protocol (without page, then with page) ending in the rank-2 teach-back. |

## Provenance

- `error.txt` was captured, not typed: same message shape as the locked
  snapshot `test/type_errors/expected_compile.txt` (`supervisor_ref_leak.ml`
  case), regenerated for the rigged file.
- The full corpus behind the page: `test/type_errors/` (10 compile cases +
  3 runtime scenarios), drift-gated by `dune runtest`.

## Note for the reviewer

Phase 1 is the measurement — please genuinely attempt it before opening the
excerpt. The experiment's pass bar lives in QUESTIONS.md item 6.
