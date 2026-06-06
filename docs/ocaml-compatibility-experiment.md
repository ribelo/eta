# OCaml Compatibility Experiment

Date: 2026-06-06

## Decision

Keep upstream OCaml compatibility.

Eta should support two compiler tiers:

- OxCaml is the performance tier.
- Upstream OCaml is the compatibility and distribution tier.

The experiment did not make upstream OCaml match OxCaml on allocation-sensitive
effect combinator chains. It did show that keeping the code compatible with
upstream OCaml does not require giving up the OxCaml performance path.

## Verification

The current revision was checked with upstream OCaml:

```sh
nix develop .#mainline -c dune runtest test/eta test/stream test/schema --force
```

The checked surface passed under OCaml 5.4.1.

The current revision was benchmarked with both compilers:

```sh
nix develop .#oxcaml -c bash bench/run.sh --quick
nix develop .#mainline -c bash bench/run.sh --quick
```

The OxCaml build emitted safety alerts around direct use of
`Domain.DLS` and `Domain.spawn`. Those alerts are useful follow-up work, but
they did not prevent the current revision from compiling and benchmarking under
OxCaml.

## Performance Summary

Current code compiled with OxCaml is generally equal to or faster than the
pre-compatibility OxCaml baseline on the main rows inspected:

- effect bind/map chains remain zero-allocation under OxCaml;
- stream `merge` and `flat_map_par` rows improved substantially;
- schema test helpers no longer pay per-assertion runtime setup;
- test clock adjustment is now zero-allocation and faster than baseline;
- file-stream, HTTP codec, SQL, and Par rows are mostly unchanged or noisy.

Current code compiled with upstream OCaml remains slower in the places where
OxCaml's allocation model matters most:

- `effect.core.map_chain.*` allocates heavily on upstream OCaml;
- bind chains allocate on upstream OCaml but stay zero-allocation on OxCaml;
- some queue, Par, HTTP codec, and file-stream rows remain slower on upstream
  OCaml.

This is expected. Upstream OCaml cannot recover the same allocation profile for
Eta's current effect API without changing semantics or exposing a different API.

## Allocation Summary

Baseline OxCaml versus current OxCaml is the important comparison for deciding
whether compatibility hurt the fast path. It did not.

Representative allocation rows, formatted as minor/major words:

| benchmark | baseline OxCaml | current OxCaml | conclusion |
| --- | ---: | ---: | --- |
| `effect.core.bind_right.10k` | 0 / 0 | 0 / 0 | unchanged |
| `effect.core.bind_left.10k` | 0 / 0 | 0 / 0 | unchanged |
| `effect.core.map_chain.10k` | 0 / 0 | 0 / 0 | unchanged |
| `effect.core.map_chain.100k` | 1.05M / 0 | 0 / 0 | better |
| `eta_stream.merge.simple` | 3.67M / 68.5k | 0 / 0 | better |
| `eta_stream.flat_map_par.64.4` | 1.05M / 0 | 0 / 0 | better |
| `schema_test.roundtrip.10k` | 13.26M / 45.7k | 0 / 0 | better |
| `test.clock.adjust.10k` | 0 / 0 | 0 / 0 | unchanged |
| `par.par_for.100k` | 3.5k / 100.3k | 3.5k / 100.3k | unchanged |
| `http.ws.codec.encode.masked_binary_960b.100k` | 24.12M / 1.4k | 24.12M / 1.4k | unchanged |

## Follow-up Work

- Keep running benchmark comparisons with both compilers.
- Treat upstream OCaml compatibility as supported, but do not present it as the
  high-performance compiler target.
- Add or keep tests for boundaries previously protected by OxCaml modes:
  domain transfer, portable data assumptions, cancellation, and concurrent
  runtime state.
- Investigate the OxCaml multidomain alerts separately. They are correctness
  signals and should not be hidden by compatibility work.
