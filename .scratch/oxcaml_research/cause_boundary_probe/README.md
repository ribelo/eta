# Cause Boundary Probe

Backlog: Effet-OxCaml-vyr.

Question: what portable representation should Effet use when Cause.Die crosses
Parallel domains?

Run:

    nix develop .#oxcaml -c bash scratch/oxcaml_research/cause_boundary_probe/run.sh

The lab compares raw exn/backtrace, materialized string diagnostics, typed
defect values, and explicit conversion from the same-domain Cause.Die shape.

