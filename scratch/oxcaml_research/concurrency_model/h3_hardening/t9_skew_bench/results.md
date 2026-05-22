# T9 Skew Benchmark Results

## Verdict

H3 remains viable. H4 does not reopen.

The current pinned dispatch policy is explicit coordinator least_loaded
assignment. skew_aware also stayed within the 1.5x-single-domain bound in the
latest run, so it remains a fallback, but it is not the pinned default.

## Evidence

Command:

nix develop -c bash scratch/oxcaml_research/concurrency_model/h3_hardening/t9_skew_bench/run.sh

Latest executable verdict:

verdict chosen_policy=least_loaded h4_reopen=false round_robin_pathology=false least_loaded_within_1_5x_single=true skew_aware_within_1_5x_single=true
summary: pass=2 fail=0

The full raw matrix is recorded in results/skew_matrix.out.

Negative control: round_robin_skew_negative.ml detected a deterministic
imbalance: left=2400 right=30 ratio=80.0.

## Pinned Invariant

H3 uses explicit coordinator assignment with least-loaded load balancing.
Portable_ws_deque remains reserved for a future H4 if production telemetry
trips the C6 reopen threshold.
