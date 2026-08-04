# Atomic phase entry

Type: prototype
Status: resolved
Blocked by: none

## Question

Does transaction identity exhaustion reproduce N1 and leave the graph stuck in
the pure phase?

Build the smallest throwaway fault-injection probe. Force the next transaction
identity allocation to fail. Observe the returned error, stabilization state,
transaction state, and a later stabilization attempt.

Compare an integer allocator with a fresh physical token only far enough to
expose the required phase-entry invariant. Do not implement the production fix.
Link the prototype as an asset.

## Answer

Yes. N1 reproduces exactly, and the graph stays stuck in the pure phase.

Forced identity exhaustion makes `stabilize` exit with an `Invalid_argument`
defect instead of a typed failure. The graph then reports `pure`, an active
pure-transaction status, and no transaction.

Each later `stabilize` call returns `Reentrant_stabilization` and leaves that
same state. The wedge is permanent, and the public interface has no recovery
operation.

A control stabilization before fault injection returns `idle` with no status and
no transaction. Thus the harness alone does not change the phase.

The defect needs two conditions. Phase entry writes two fields before it
allocates the transaction identity, and the pass-level `try` block starts after
phase entry returns.

### Required phase-entry invariant

Identity construction must complete before any phase field changes. Phase entry
must then return a pure token with a live transaction, or preserve the prior
idle state exactly. No observable state can hold `pure`, an active status, and
no transaction.

### Identity representation

A fresh physical token is sufficient for distinguishing pending cells. It needs
no counter and no module-global allocator, so it removes both the `max_int`
failure and the cross-domain race.

The representation change alone does not close the defect, because any
allocation can raise `Out_of_memory`. The ordering invariant above is the
necessary part.

[Transaction and invalidation model](09-transaction-and-invalidation-model.md)
owns the phase model, the identity representation, and the typed error name.
[Laws and economics gates](16-laws-and-economics-gates.md) owns the regression
and law decisions.

### Evidence

The prototype is on branch `prototype/eta-signal-atomic-entry` at commit
`c3642f3f`. Run it with one command:

```sh
bash .scratch/prototypes/eta-signal-atomic-entry/run.sh
```

The command exits with status `0` and fails if the observed state differs from
the N1 counterexample.

- [Probe results](../../../../.scratch/research/eta-signal-direction/atomic-phase-entry/RESULTS.md)

### Census rows resolved here

`EXE-009`, `N01-002`, `N01-003`, `N01-004`, `N01-005`, `N01-006`, `N01-007`,
`N01-008`, `N01-009`, `N01-011`, `N01-012`, `N01-013`, `N01-014`, `N01-029`,
`S12-003`, and `S14-001`.
