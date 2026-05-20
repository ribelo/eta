# Bench Research

Effet-7bu research output for the continuous bench suite.

Decisions:

- Runtime timing uses the existing custom pattern: `Unix.gettimeofday` plus
  `Gc.quick_stat`. This keeps the bench suite dependency-free and matches the
  earlier stream research lab.
- Compile-time timing uses a shell wrapper around `date +%s%3N`; `/usr/bin/time`
  is treated as optional metadata because it is not always available in the Nix
  shell.
- History is committed JSON in `bench/results/`.
- `dune build @bench` runs runtime benchmark executables only. Compile-time
  benchmarks stay in `bench/run.sh` because they intentionally measure Dune.
- Quick mode runs one sample. Full mode runs five runtime samples and three
  compile-time samples.
- Machine fingerprint fields are OS, kernel, CPU model, CPU count, OCaml
  version, and Dune version.

Run the lab:

```sh
nix develop -c dune exec scratch/bench_research/a_custom_baseline.exe -- --quick
nix develop -c bash scratch/bench_research/compile_time_candidates.sh
```
