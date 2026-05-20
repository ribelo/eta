# Effet Overhead Benchmark Research

## Question

The benchmark suite must answer this question without ad hoc throwaway code:

> What does Effet cost compared with ordinary OCaml for the same kind of work?

The current suite answers a different question: whether Effet gets faster or
slower over time. That remains useful, but it is not an overhead answer.

## Decision

Add a small paired-overhead layer. Do not replace the current harness, do not add
Core_bench/Bechamel yet, and do not create a large benchmark taxonomy.

The right v2 is roughly one new runtime executable plus one ratio reporter:

- `bench/runtime_overhead/` emits both Effet and base OCaml controls.
- `bench/overhead.ml` reads one result JSON and prints ratios.

Keep result JSON raw. Compute ratios in the reporter so the schema does not grow
until the pair map proves stable.

## Minimal Workloads

These are enough to answer the question we actually ask.

| Question | Effet workload | Base workload | Ratio |
| --- | --- | --- | --- |
| Pure interpreter floor | reused-runtime `Effect.pure` loop | direct OCaml loop | `effet_pure / ocaml_loop` |
| Bind cost | reused-runtime `Effect.bind` chain | direct closure-bind chain | `effet_bind / ocaml_bind` |
| Typed failure cost | `Effect.fail |> catch` loop | `Result.Error |> match` loop | `effet_fail_catch / result_error` |
| Runtime setup cost | current `Runtime.create + run` | `Eio_main.run + Switch.run` only | `effet_setup / eio_setup` |
| One realistic pipeline | one existing stream or schema workload | hand-coded equivalent | `effet_macro / direct_macro` |

That is the whole first pass. No observability matrix, no compiler matrix, no
large stream/schema mirror.

## Measurement Rules

- Each pair runs in the same executable and same result file.
- Base OCaml controls must use `Sys.opaque_identity` and a sink, otherwise
  native compilation can erase the work.
- Microbenchmarks must run enough inner iterations that timer overhead is not
  the dominant cost.
- Report both time and allocation ratios.
- Full mode should use at least ten samples for these overhead pairs.
- Quick mode may stay one sample for convenience, but it is not enough for a
  serious overhead claim.

## Why Not A Bigger Suite

A bigger suite would answer more questions but blur the important one. The
current pain is not lack of benchmark volume; it is that the result lacks a
denominator. The smallest good fix is to add denominators and a ratio report.

## Follow-Up Implementation Task

Title: `Benchmark overhead controls and ratio report`

Acceptance:

- `bench/runtime_overhead/` exists and emits the five paired workload groups
  above.
- `bench/run.sh` includes `runtime_overhead.exe`.
- `bench/overhead.ml` prints ratios from a single result JSON.
- `bench/README.md` distinguishes trend tracking from overhead answers.
- `journal.md` records the first paired overhead result.

