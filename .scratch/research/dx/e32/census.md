# DX-E32 Census — recovery-only `fold`

## Reproduction

The orchestrator cohort is OCaml implementation files, excluding build output:

```sh
rg -U -o --glob '*.ml' --glob '!_build/**' \
  'fold\s*~ok:\s*Fun\.id\s*~error:' . | wc -l
# 26

rg -l -U --glob '*.ml' --glob '!_build/**' \
  'fold\s*~ok:\s*Fun\.id\s*~error:' . | sort
# 10 files
```

The ten files are six under `examples/`, one library implementation, and three
test implementations. A PCRE2 search for identity lambdas in `~ok` found no
`fun x -> x` or one-case `function x -> x` variants. The multiline-capable
search found no additional `Fun.id` forms beyond the 26.

There is one additional current teaching occurrence in `README.md:55`, outside
the `*.ml` cohort. Historical E23 research artifacts are provenance, not current
usage, and are excluded.

## Classification rules

- **Constant/error-independent:** the error callback does not use the error
  payload to compute its result. This includes defect probes whose callback
  raises and fixed fallback thunks.
- **Function of error:** the callback renders, wraps, or otherwise uses the
  error value (including pattern selection across error constructors).
- **Consumer-shaped:** runnable examples or snippets/fixtures deliberately
  modeling application code.
- **Framework:** library implementation, runtime/core tests, or scanner
  machinery.
- **Scanner sentinel:** a string searched by a meta-test, not a fold call or
  teaching snippet. It explains the textual count but is not a recovery site.

## Per-occurrence census

| Source | Line(s) | Error shape | Consumption shape | Kind |
|---|---:|---|---|---|
| `examples/bounded_channel.ml` | 42 | function of error | consumer-shaped | executable call |
| `examples/fold_recovery.ml` | 10 | constant | consumer-shaped | executable call |
| `examples/fold_recovery.ml` | 14 | constant | consumer-shaped | executable call / defect demonstration |
| `examples/pubsub_subscription.ml` | 24 | function of error | consumer-shaped | executable call |
| `examples/quickstart.ml` | 11 | constant | consumer-shaped | executable call |
| `examples/semaphore_permits.ml` | 17 | function of error | consumer-shaped | executable call |
| `examples/unbounded_queue.ml` | 34 | function of error | consumer-shaped | executable call |
| `lib/http/server_handler.ml` | 30 | function of error | framework | executable call |
| `test/core_common/effect_common_suites.ml` | 565 | constant | framework | recovery test |
| `test/core_common/effect_common_suites.ml` | 570 | constant | framework | defect pass-through test |
| `test/core_common/effect_common_suites.ml` | 579 | error-independent raise | framework | callback-defect test |
| `test/core_common/effect_common_suites.ml` | 603 | error-independent raise | framework | callback-defect test |
| `test/core_common/effect_common_suites.ml` | 700 | constant | framework | success/fallback test |
| `test/core_common/effect_common_suites.ml` | 706 | constant | framework | typed-failure fallback test |
| `test/core_common/effect_common_suites.ml` | 714 | constant | framework | defect pass-through test |
| `test/core_common/effect_common_suites.ml` | 752 | constant | framework | defect pass-through test |
| `test/core_common/effect_common_suites.ml` | 761 | constant | framework | interruption pass-through test |
| `test/api_dx/api_dx_examples.ml` | 181 | function of error | consumer-shaped | compiled DX fixture |
| `test/api_dx/api_dx_examples.ml` | 192 | function of error | consumer-shaped | compiled predecessor fixture |
| `test/api_dx/api_dx_examples.ml` | 1352 | function of error | consumer-shaped | pedagogical snippet |
| `test/api_dx/api_dx_examples.ml` | 1370 | function of error | consumer-shaped | predecessor snippet |
| `test/api_dx/api_dx_examples.ml` | 2646 | n/a | framework | positive scanner sentinel |
| `test/api_dx/api_dx_examples.ml` | 2671 | n/a | framework | negative scanner sentinel |
| `test/runtime_common/runtime_common_suites.ml` | 98 | constant | framework | recovery test |
| `test/runtime_common/runtime_common_suites.ml` | 100 | constant | framework | defect pass-through test |
| `test/runtime_common/runtime_common_suites.ml` | 104 | error-independent raise | framework | callback-defect test |

## Totals and interpretation

| Measure | Count |
|---|---:|
| Textual cohort | 26 occurrences / 10 files |
| Scanner sentinels rather than usage | 2 |
| Executable calls or pedagogical snippets | 24 |
| Constant/error-independent among those 24 | 15 |
| Functions of the error among those 24 | 9 |
| Consumer-shaped in textual cohort | 11 |
| Framework in textual cohort (including 2 sentinels) | 15 |
| Example files | 6 / 10 |
| Example occurrences | 7 / 26 |
| Additional current README teaching site | 1 |
| Identity-lambda variants found | 0 |

The headline **26 / 10** is reproducible as a textual metric, but “26 sites”
overstates semantic use by two scanner sentinels. The corrected cohort still has
**24 real expressions/snippets**, exceeds the preregistered approximate-20
frequency bar, and contains **11 consumer-shaped occurrences** plus the README
site. Frequency therefore supports candidate B; it does not decide the separate
exception-misreading gate.

The consumption model cuts both ways. Six of ten files are examples, making the
ceremony conspicuous in the teaching surface. But only seven of the 26 textual
occurrences live there, and `fold_recovery.ml` intentionally teaches that
defects pass through; replacing its spelling with `recover` would make that
lesson depend more heavily on readers overriding the name's broad implication.
