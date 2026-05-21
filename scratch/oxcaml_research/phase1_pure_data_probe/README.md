# Phase 1 Pure Data Probe

This lab covers the non-Cause pure data slice of `Effet-OxCaml-unm`.

- `pure_data_parallel_positive.ml` moves Duration, Schedule, Trace_context, Sampler, Capabilities payload records, Logger/Meter payloads, and Tracer span metadata through `Parallel.fork_join2`.
- `portable_function_payload_negative.ml` and `portable_ref_payload_negative.ml` prove the chosen kind boundary rejects function/ref payloads.
- `sampler_field_escape_negative.ml` proves `Sampler.t` no longer exposes a closure field.

Run:

`nix develop .#oxcaml -c bash scratch/oxcaml_research/phase1_pure_data_probe/run.sh`
