# Scala + ZIO Reference Bench

Mirrors the old Bun + Effect reference suite for Scala ZIO. It is an opt-in
comparison aid, not part of the default package benchmark suite.

## Running

```sh
nix develop -c bash bench/runtime_overhead_zio/run.sh
nix develop -c bash bench/runtime_overhead_zio/run.sh --quick
nix develop -c bash bench/runtime_overhead_zio/run.sh --quick --filter 'zio.bind'
```

The runner emits one JSON object per benchmark row, matching `Bench_lib`.
If `scala-cli` or `java` is missing, it prints a notice and exits 0.

## Caveats

- Eta is native OCaml/OxCaml; ZIO runs on the JVM. Treat this as directional
  reference data, not a release gate.
- ZIO's runtime and the JVM JIT have different warmup and heap behavior.
  Each workload does one untimed warmup and requests a GC between samples.
- Only `wall_ns` is emitted; JVM allocation accounting is intentionally omitted.
