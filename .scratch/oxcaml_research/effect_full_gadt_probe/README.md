# Full Effect.t GADT Kind Probe

Backlog: Effet-OxCaml-uwr.

Question: can the full current Effect.t shape carry one set of OxCaml kind
constraints, or must Phase 4 split the AST?

Run:

    nix develop .#oxcaml -c bash scratch/oxcaml_research/effect_full_gadt_probe/run.sh

Candidates:

- candidate_a_one_gadt.ml tries one portable GADT covering the real constructor
  set plus supervisor_body / supervisor_scope.
- candidate_b_split.ml splits a portable pure core
  (Pure / Fail / Thunk / Bind / Map / Catch) from same-domain runtime I/O.
- candidate_b_split_negative.ml proves the portable core rejects a callback
  that captures int ref.
- candidate_b_polyvariant_error_negative.ml proves the requested immutable_data
  error kind rejects Effet's current open polymorphic-variant error style.
- candidate_c_mode_template.ml tests a mode-polymorphic template over
  portable/nonportable instead of a manual split.

Results are captured under results/.
