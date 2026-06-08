# P0-T7 PPX OxCaml Probe

Status: final for Effet-OxCaml-3gk.

Question: can ppx_effet's current expansion style work with OxCaml mode/kind-annotated Effect APIs, and does the pinned ppxlib carry mode syntax?

## Artifacts

- ppxlib_parse_modes_positive.ml: parses OxCaml value-binding mode syntax through Ppxlib.Parse and verifies pvb_modes is populated.
- current_ast_helper_shape.ml: confirms the current Ast_builder.Default pexp_fun helper still builds a normal function node.
- current_style_expansion_positive.ml: representative ppx_effet thunk/capability expansion compiles against a mode-annotated Effect.thunk API without emitting explicit mode syntax.
- current_style_capture_negative.ml: current-style expansion rejects a closure that captures int ref when Effect.thunk requires a portable callback.
- results/compile.out and per-fixture logs: command transcripts.

## Command

    nix develop .#oxcaml -c bash scratch/oxcaml_research/ppx_oxcaml_probe/run.sh

Last result:

    summary: pass=4 fail=0

## Evidence

The pinned Jane/OxCaml ppxlib parses OxCaml value-binding mode syntax. The parser accepts a portable value binding and exposes a non-empty pvb_modes list.

The current ppx_effet expansion style can remain source-compatible for thunk/capability expansion. A plain generated function passed to a helper whose argument is portable compiles, and the callback is inferred portable.

Capture safety still comes from the callee API. The negative fixture uses the same current-style expansion shape but captures int ref; the compiler rejects it because Effect.thunk expects a portable callback.

The current Ast_builder.Default.pexp_fun helper builds ordinary function nodes with no explicit modes. That is acceptable for thunk/env expansions that call mode-annotated helper functions, but not sufficient if Phase 4 needs the PPX to create explicit mode-bearing value bindings or type declarations.

## Decision diary

- V-P0T7-1 - Keep ppx_effet's helper-call expansion style where possible.
  Decision: for [%effet.thunk], capability lookup, and env binding, Phase 4 should prefer expanding to calls of mode-annotated Effect helper functions rather than emitting explicit mode syntax.
  Rationale: current_style_expansion_positive compiles and current_style_capture_negative proves portable capture checks still fire.

- V-P0T7-2 - Use Jane/OxCaml ppxlib APIs for explicit mode nodes.
  Decision: if a PPX expansion must emit explicit mode-bearing bindings or type declarations, use the Jane/OxCaml ppxlib AST path, not upstream assumptions.
  Rationale: ppxlib_parse_modes_positive proves the pinned ppxlib carries pvb_modes. Current default helpers produce normal mode-empty function nodes.

- V-P0T7-3 - No raw-source escape hatch is needed for the covered ppx_effet expansions.
  Decision: do not introduce string-based source generation for thunk/capability/env expansion.
  Rationale: the compiler can infer portability from helper signatures, which is safer than generating source fragments.

## Deferred

- Phase 4 should add a focused ppx_effet test once the real Effect.thunk signature is updated to require portable callbacks.
- If Phase 4 adds PPX-generated type declarations or explicit mode-bearing value bindings, add a dedicated Ppxlib_jane builder fixture before implementation.

