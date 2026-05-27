# P-Scoped-4: Evidence Repair

## Scope

This pass repairs the original scoped-session lab evidence gap. It adds
runnable artifacts for the load-bearing claims:

- Branch C can express a supervised session with existing primitives.
- A child handle from Supervisor.scoped cannot escape the rank-2 scope.
- Branch B as a generic helper is just the Branch C recipe packaged as one
  local function.

## Artifacts

- branch_c_supervised_session.ml: runtime smoke fixture using Effect.scoped,
  Effect.acquire_release, Supervisor.scoped, and Scope.start.
- branch_b_local_wrapper.ml: local with_session wrapper; its body is only the
  Branch C recipe.
- negative/child_escape_negative.ml: compile-negative fixture for child handle
  escape.
- ws_client_branch_c.patch: real patch-shaped WebSocket refactor sketch.

## Verdict

Branch C remains the supported decision: document the recipe; do not add a
public scoped-session API yet.

Branch B is dominated by Branch C in the compiled fixture. The helper body is
only Effect.scoped plus Effect.acquire_release plus Supervisor.scoped plus
Scope.start. It centralizes no invariant beyond those existing primitives.

Branch A remains rejected. The negative fixture validates the rank-2 observation
directly. Any helper built on Supervisor.scoped inherits that non-escape
property. A helper that allows escape would need different machinery and would
reopen the private-daemon design boundary.

## Verification

Commands run from the repository root:

- nix develop .#oxcaml -c dune exec ./scratch/eta_research/scoped_sessions/p_scoped_4/branch_c_supervised_session.exe
  - Result: PASS, see results/branch_c_supervised_session.log.
- nix develop .#oxcaml -c dune exec ./scratch/eta_research/scoped_sessions/p_scoped_4/branch_b_local_wrapper.exe
  - Result: PASS, see results/branch_b_local_wrapper.log.
- nix develop .#oxcaml -c dune build ./scratch/eta_research/scoped_sessions/p_scoped_4/negative/child_escape_negative.exe
  - Result: expected compile failure, see results/child_escape_negative.log.
- git apply --check scratch/eta_research/scoped_sessions/p_scoped_4/ws_client_branch_c.patch
  - Result: PASS, see results/ws_client_branch_c_apply_check.log.

Plain dune without the OxCaml shell is not a valid gate for this repository. It
uses syntax and dependencies supplied by the shared OxCaml switch.
