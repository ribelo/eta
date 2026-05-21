# Supervisor State Probe

Backlog: Effet-OxCaml-r18.

Question: should supervisor failure state use Capsule-protected mutable state
or a Portable.Atomic immutable list?

Run:

    nix develop .#oxcaml -c bash scratch/oxcaml_research/supervisor_state_probe/run.sh

