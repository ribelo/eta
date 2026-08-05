# Incremental layered baseline

Type: research
Status: resolved

## Question

What exact execution model and costs make Incremental the zero-effect reference
for each matched workload?

Trace the source paths for mutation, propagation, cutoffs, demand, dynamic
topology, stabilization, and observation. Identify retained state and each
steady-state allocation. Define the raw-kernel measurements that Eta must match.

## Answer

Incremental uses retained intrusive scheduling state for allocation-free static
propagation. The matched no-op observer handler allocates the observed six
words, not the raw kernel.

The raw baselines and exact source paths are in
[the Incremental layered baseline](../../../../.scratch/research/eta-signal-execution-model/incremental-layered-baseline.md).
