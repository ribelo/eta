# Effet-6yf results

Command:

    nix develop -c dune exec scratch/resource_survival/runtime_smoke.exe

Result:

    resource_survival runtime smoke passed

## LOC

    47 packages/effet/resource.ml
    27 packages/effet/resource.mli
     9 scratch/resource_survival/branch_a_resource.ml
    61 scratch/resource_survival/branch_b_atomic.ml
   127 scratch/resource_survival/runtime_smoke.ml

## Findings

Branch B can reproduce Resource behavior with an Atomic.t cell plus Effect
combinators, but the auto-refresh case is not pure ordinary userland code in
today's Effet. It needs Effect.Private.daemon, the internal runtime-owned
background primitive that replaced public detach.

Manual cached loading is a recipe. Auto-refresh with last-good retention, typed
failure history, and runtime-owned lifecycle is a library abstraction.

Recommendation: keep Resource. Do not delete it or migrate users to the raw
Atomic.t recipe. The public rationale should be narrow: Resource is the blessed
runtime-owned cached-loader, not a general resource framework.

