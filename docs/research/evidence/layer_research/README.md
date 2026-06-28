# Layer Research

This lab reopens V-R2 for two missing candidates:

- merge_explicit: a small Layer wrapper where output merging is explicit through
  combine.
- gadt_presence_set: a Tag/Context-style presence-set encoded with GADTs and
  hidden lookup witnesses.
- no_layer_baseline: ordinary OCaml service factories and bind, used as the
  control.

The shared fixture has Db and Http services. Db needs Clock; Http needs Clock
and Log. The merged app needs Clock and Log at boot.

Run positives:

    nix develop -c dune build .scratch/layer_research
    nix develop -c dune exec .scratch/layer_research/runtime_smoke.exe

Negative probes are deliberately excluded from dune. Add one executable stanza
for a neg_*.ml file at a time to capture the compiler error, then remove it.
