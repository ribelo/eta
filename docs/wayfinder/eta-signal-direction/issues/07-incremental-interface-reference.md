# Incremental interface reference

Type: research
Status: claimed
Blocked by: none

## Question

What coherent algebra does Jane Street Incremental expose, and which parts give
useful evidence for a complete Eta Signal interface?

Read the primary Incremental and Incr_map interfaces and implementation where
semantics are not clear from the interface. Classify constructors, combinators,
cutoffs, observers, lifecycle events, dynamic dependencies, folds,
introspection, memoization, snapshots, time, and expert operations.

Distinguish algebraic completeness from convenience aliases and optional
subsystems. Record where Eta's effect, package, and consumer model needs a
different interface. Evaluate leverage for external Eta consumers, not current
repository adoption. Do not propose parity as a goal. Save the report under
`.scratch/research/eta-signal-direction/`.
