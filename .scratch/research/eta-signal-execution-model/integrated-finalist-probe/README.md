# Integrated finalist probe

This durable scratch project is the issue 11 harness. It binds copies of the
public Signal tests to the separately owned `Selected_factory_fresh`. It does
not copy or modify production implementation modules. The legacy
`finalist_factory.ml` is not linked into candidate targets.

## Boundaries

- `generate.py` replaces only `Eta_signal.Make (...) ()` and
  `Eta_signal.Make_no_error ()`. It fails when it finds another factory
  expression. `generated/source-manifest.json` records SHA-256 hashes of every
  source and generated file. Tracked `source-hashes.json` freezes the source
  hashes; update it explicitly with `generate.py --record-hashes` when an
  intentional public-test revision is reviewed.
- Generated files and temporary results are ignored. Run `check_generated.py`
  to detect source drift or edited generated copies. Reviewed checkpoint
  results can be copied to tracked files in this directory.
- Generated map tests continue to use `Eta_signal_map.Make
  (Finalist.Package)`. Generated stream tests continue to use
  `Eta_signal_stream.Make (Finalist.For_stream)`.
- `finalist_native_checks.ml` replaces unique white-box observations with
  finalist-facing checks for rollback/retry, dependency-first observer order,
  and idempotent disposal. It does not assert a private representation.
- `compare_public.ml` is frozen from `bench/signal_compare/compare.ml`, source
  SHA-256
  `0b43cd9791330932c42efcc9ce4e8d2391ee4c4fc872ce7ffc62406de27de262`,
  with only the factory and Eta workload labels changed.
- `compare_raw.ml` uses the harness-owned `Raw_benchmark` adapter directly
  against the separately owned `Selected_core`. This keeps raw evidence
  available while public factory migration is in progress. Its `run_batch` is
  the measured operation. `final_read_and_check` remains after timing and
  allocation counters.

The runners preserve graph depths and map sizes, calibration from one operation
to 0.5 seconds or 16,777,216 operations, nine samples, three complete pairs,
fresh processes, CPU pinning, and
`minor + major - promoted` allocation accounting.

## Run

Use the repository Nix/OxCaml shell only:

```sh
nix develop -c dune build --root \
  .scratch/research/eta-signal-execution-model/integrated-finalist-probe \
  @selected-core-check
nix develop -c dune build --root \
  .scratch/research/eta-signal-execution-model/integrated-finalist-probe \
  @selected-edges-check
nix develop -c .scratch/research/eta-signal-execution-model/integrated-finalist-probe/run.sh tests
nix develop -c .scratch/research/eta-signal-execution-model/integrated-finalist-probe/run.sh raw-smoke
nix develop -c .scratch/research/eta-signal-execution-model/integrated-finalist-probe/run.sh performance
```

`@selected-core-check` builds the separately owned `selected_core.ml` and runs
the separately owned `selected_core_check.ml` without routing through the
finalist factory.

`@selected-edges-check` does the same for the separately owned post-commit edge
driver and its check module.

`run.sh tests` reports compile and runtime status for each suite separately, so
one failure does not hide later suites. Performance output is written under
ignored `results/`. The checkpoint files preserve reviewed diagnostic runs.

`run.sh raw-smoke` runs one CPU-pinned reference/finalist pair with one sample
per raw workload. It records correctness, allocation, and the first allocation
or paired wall-time failure in ignored `results/raw-smoke.tsv`.
