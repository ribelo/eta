# Hill-Climbing Prompt: radical-rust-catching-router

## Goal
Improve `eta_router` lookup throughput until it is within 3× of the upstream Rust `matchit` implementation on an identical workload.

## Metric contract
- **Primary metric**: `ocaml_ns_per_lookup` (nanoseconds per lookup, lower is better).
- **Target**: `ocaml_ns_per_lookup <= 50 ns` (Rust matchit is ~16.5 ns/lookup on this machine, so 3× ≈ 50 ns).
- **Secondary metrics**: `rust_ns_per_lookup`, `ratio` (OCaml / Rust).
- **Benchmark command**: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id radical-rust-catching-router`
- **Checks command**: `.hill-climbing/radical-rust-catching-router/checks.sh`

## Scope
- **In scope**: `lib/router/*.ml`, `lib/router/*.mli`, `bench/router/ocaml/*`, `bench/router/rust/*`.
- **Off limits**: `test/router/test_eta_router.ml` (do not weaken tests to get a better metric), the route/path data sets (`bench/router/routes.txt`, `bench/router/paths.txt`), and the workload size.

## Anti-gaming
Do not reduce the workload, remove routes, weaken `checks.sh`, special-case benchmark inputs, cache results across iterations invalidly, or trade correctness for speed. The benchmark must continue to exercise the full route set with the same number of lookups.

## How to climb
1. Read `JOURNAL.md` for the current hypothesis space and latest results.
2. Call `create_goal` with an objective tied to the primary metric.
3. Make one scoped change.
4. Run the benchmark facade (`python ... run --id radical-rust-catching-router`).
5. Run `checks.sh` (the facade runs it automatically, but verify failures independently if needed).
6. Manually update `JOURNAL.md` with the experiment entry, verdict, and next hypothesis.
7. Commit changes that improve the metric and pass checks; revert changes that regress or game the benchmark.
