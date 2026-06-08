# Bind Once Probe

Backlog: Effet-OxCaml-ss6.

Question: should the OxCaml rewrite make Effect.t values once/linear so Bind
and Map continuations can be once, or should Effect.t stay reusable with
portable callbacks?

Run:

    nix develop .#oxcaml -c bash scratch/oxcaml_research/bind_once_probe/run.sh

