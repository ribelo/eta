# Eio Wrapper Probe

Backlog: Effet-OxCaml-07e.

Question: what mode-annotated wrapper surface should Effet put around raw Eio
handles while keeping Eio as the local fiber and IO substrate?

Run:

    nix develop .#oxcaml -c bash scratch/oxcaml_research/eio_wrap_probe/run.sh

