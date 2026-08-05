---
kind: requirement
---
# Benchmark and AI fixture support

## Intent

Keep non-production benchmark and fixture mechanics in shared test-only
support without widening published package surfaces.

## Requirements

- The `Bench_lib` module shall expose an allocation-free operation that invokes a unit callback a requested number of times. ^benchlib-s9u1
- When the requested benchmark repetition count is zero or negative, `Bench_lib` shall not invoke the callback. ^benchlib-cg02
- The `Bench_lib` module shall expose normalization of a per-run measurement by a positive operation count, and shall reject a non-positive operation count. ^benchlib-4knd
- `Bench_lib` shall report a median for every emitted metric, computed so that a single outlying sample cannot move it. ^benchlib-p73c
- Eta AI benchmarks shall obtain the shared weather schema and weather tool fixtures from benchmark-only support. ^benchlib-35y8
- Eta AI provider tests shall obtain repeated fixture reading and result assertion behavior from a private Dune library under `test/ai`. ^benchlib-ign9
