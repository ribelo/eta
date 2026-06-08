# I2 / H2 - OxCaml portable callback island

Date: 2026-05-22

## Verdict

H2 holds. A small callback island can run the same finite CPU-offload workloads
as the mainline baseline, while adding compiler-enforced rejection of the
captures that Design A can only document as policy errors.

The winning claim is safety, not universal performance.

## Apples-To-Apples Controls

- Workloads: same parse/validate, schema decode, hash/checksum/compress shapes
  as Design A.
- Items: 128 per workload.
- Parallelism: bounded at 2 worker domains.
- Result contract: input order.
- Error contract: typed result-returning callbacks, plus worker_die diagnostic
  for callback crashes.
- Runtime contamination: Eio and Effet runtime handles are rejected in portable
  callbacks.

The substrate differs by design: Design A uses a normal OCaml domain pool;
Design B uses OxCaml Parallel_scheduler. Therefore wall times are directional
only. They are not the decision criterion.

The fixture reuses one island scheduler for the three workload runs. A
diagnostic fixture, diagnose_island_timing.ml, showed that creating a fresh
Parallel_scheduler for each workload injects about 50ms into the second and
third scheduler creation. That was a fixture artifact, not workload execution.

## Positive Evidence

Fixtures:

- portable_map_positive.ml
- ordered_results_positive.ml
- all_settled_positive.ml
- atomic_capture_positive.ml
- workloads_positive.ml
- worker_die_diagnostic_positive.ml

Latest output excerpt:

    island portable_map=true
    island ordered_results=true items=32 bounded=2
    island all_settled=true oks=16 typed_errors=4
    island atomic_capture=true final=2
    island workload=parse_validate items=128 ok=127 typed_errors=1 bounded=2 wall_us=362
    island workload=schema_decode items=128 ok=127 typed_errors=1 bounded=2 wall_us=230
    island workload=hash_checksum_compress items=128 ok=127 typed_errors=1 bounded=2 wall_us=146
    island worker_die_diagnostic=true kind=Failure

## Negative Evidence

The compiler rejected all bad-capture fixtures:

- ref_capture_negative.ml: mutable ref use is contended inside a portable
  function.
- eio_stream_capture_negative.ml: Eio.Stream.add is nonportable.
- runtime_capture_negative.ml: Effet.Runtime.run is nonportable.
- logger_capture_negative.ml: Effet.Logger.dump is nonportable.
- raw_cause_capture_negative.ml: raw same-domain Cause.t is nonportable.

This is the material difference from Design A.

## H2 Status

Accepted for the optional island path. Design B beats Design A on compiler
safety, while keeping the surface smaller than a portable Effect AST.
