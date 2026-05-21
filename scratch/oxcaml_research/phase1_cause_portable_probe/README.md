# Phase 1 Cause.Portable Probe

This lab is the first shipped-code slice for `Effet-OxCaml-unm`.

- `portable_cause_parallel_positive.ml` converts same-domain `Cause.t` into `Cause.Portable.t` and moves the result through `Parallel.fork_join2`.
- `raw_cause_parallel_negative.ml` tries to move raw same-domain `Cause.t` through `Parallel`; this must fail.
- `portable_payload_ref_negative.ml` tries to put a closure capturing a ref into `Cause.Portable.Fail`; this must fail.

Run:

`nix develop .#oxcaml -c bash scratch/oxcaml_research/phase1_cause_portable_probe/run.sh`
