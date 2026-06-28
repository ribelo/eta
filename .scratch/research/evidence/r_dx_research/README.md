# R-channel DX Research

Synthetic 20-module app for measuring object-row env developer experience at
larger scale.

Variants:

- env-row: current Effet style, effects read capabilities from the runtime env.
- args: explicit named service arguments.
- bag: one composite services object passed as a value.

Generate:

~~~sh
nix develop -c ocaml .scratch/research/evidence/r_dx_research/generate_fixture.ml
~~~

Run positives:

~~~sh
nix develop -c dune build .scratch/research/evidence/r_dx_research
nix develop -c dune exec .scratch/research/evidence/r_dx_research/runtime_smoke.exe
~~~

Measure:

~~~sh
nix develop -c bash .scratch/research/evidence/r_dx_research/measure.sh
~~~

Negative probes are excluded from dune. Add one executable stanza for a
neg_*.ml module at a time to capture the compiler output.
