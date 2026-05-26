# Scala + ZIO Reference Bench

Mirrors the old Bun + Effect reference suite for Scala ZIO. It is an opt-in
comparison aid, not part of the default package benchmark suite.

## Running

```sh
nix develop -c bash bench/runtime_overhead_zio/run.sh
nix develop -c bash bench/runtime_overhead_zio/run.sh --quick
nix develop -c bash bench/runtime_overhead_zio/run.sh --quick --filter 'zio.bind'
nix develop -c bash bench/runtime_overhead_zio/run.sh --samples 30 --warmup-ms 5000
```

The runner emits one JSON object per benchmark row, matching `Bench_lib`.
If `scala-cli` or `java` is missing, it prints a notice and exits 0.
Full runs warm each workload for 2 seconds before measurement and collect
10 measured samples. `--quick` uses 100 ms of warmup and one sample.

## Caveats

- Eta is native OCaml/OxCaml; ZIO runs on the JVM. Treat this as directional
  reference data, not a release gate.
- ZIO's runtime and the JVM JIT have different warmup and heap behavior.
  Each workload uses a timed warmup and requests a GC between measured samples.
  The wrapper also fixes the JVM heap to 1 GiB with `-Xms1g -Xmx1g` and
  pre-touches it to reduce heap-growth noise.
- Only `wall_ns` is emitted; JVM allocation accounting is intentionally omitted.
