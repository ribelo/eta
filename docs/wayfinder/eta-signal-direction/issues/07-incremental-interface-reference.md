# Incremental interface reference

Type: research
Status: resolved
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

## Answer

Incremental's coherent algebra is small: graph instances, constants and
variables, fixed maps, dynamic `bind`/`join`/`if_`, cutoffs, demand-driven
observers, stabilization, and folds. `Clock`, memoization, diagnostics,
`Expert`, and `Incr_map` are separate extensions, conveniences, or
performance subsystems.

The reference gives Eta useful evidence for demand, cutoff placement,
dynamic-branch invalidation, observer lifecycle, associative and
change-proportional folds, and explicit time boundaries. Eta does not need
Incremental parity. Eta's effectful updates and stabilization, typed failures,
desired transaction boundary, explicit disposal, runtime ownership, timer
daemon, and separate `eta_signal_map` package require different contracts.

The requested `incremental` checkout has no `Incr_map` source. The primary
`Incr_map` checkout is the sibling `/home/ribelo/projects/github/incr_map`.
The report records both immutable commit identities, exact symbols and line
ranges, interface and implementation checks, source mismatches, and
verification limits.

Research report:

- [Incremental interface reference](../../../../.scratch/research/eta-signal-direction/incremental-interface-reference.md)

### Census rows resolved here

- Observer lifecycle: `F04-006` and `F04-008`.
- Algebra and variable reads: `F09-003` and `F09-011`. Eta's `Var.value` covers
  external latest-source reads, not reads during pure recomputation.
- Default bind invalidation: `F11-004`, `F11-005`, and `S05-002`.
- Cutoff controls: `F12-003`.
