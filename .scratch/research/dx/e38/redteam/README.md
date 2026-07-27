# DX-E38 follow-up red-team cases

The executable assertions live in normal project suites so the repaired design
remains gated after the research branch.

| Attack | Required observation | Executable test |
| --- | --- | --- |
| Release fails without `error_pp` | Full output remains `Finalizer(Fail("<typed failure>"))`. | `release failure without error_pp keeps default finalizer render` in `test/ppx_common/ppx_common_suites.ml` |
| Release fails under E7-derived `pp_err` | Capture stores `db:7`; full output remains `Finalizer(Fail("db:7"))`. | `derived eta_error printer renders release finalizer failure` in `test/ppx_common/ppx_common_suites.ml` |
| Registered-release printer raises during conversion | The runtime returns top-level `Cause.Die`; no later Portable/render call raises the printer exception. | Native `eta_error raising release renderer`; jsoo `raising release error_pp becomes die at conversion` |
| `Effect.finally` printer raises during conversion | Conversion is outside the cleanup-execution catch, so the result is top-level `Cause.Die`, not `Cause.Finalizer.Die`. | Native `eta_error raising finally renderer`; jsoo `raising finally error_pp becomes die at conversion` |
| Printer is total but stateful | It runs once at capture; both equality modes remain reflexive and never rerun it. | `finalizer equality is reflexive after stateful capture` in `test/core_common/cause_exit_common_suites.ml` |
| Typed value could still be flattened | Conversion stores the expected string and the original existential value by physical identity. | `finalizer fail preserves typed payload and leaves typed channel` in `test/core_common/cause_exit_common_suites.ml` |

## Outcome

All attacks passed under native and mainline js_of_ocaml gates:

```sh
nix develop -c dune runtest test/core_eio test/ppx_eio test/otel_eio test/laws --force
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force
```

The repaired payload stores no printer. Therefore public rendering, equality,
squash, and Portable conversion cannot execute the original `error_pp` outside
Eta's capture boundary.
