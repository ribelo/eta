# Atomic phase entry: executable evidence for N1

## Question

Does transaction identity exhaustion reproduce N1 and leave the graph stuck in
the pure phase?

## Method

The probe uses the public `stabilize` effect of one graph. It reaches that graph
through the approved overflow harness in `test/signal/`.

Two prototype-only functions support the probe. One forces the next transaction
identity. The other reads the phase, the pure-transaction status, and the
presence of a transaction while the graph lane is held.

The observation boundary is the graph lane after each `stabilize` exit. That
boundary is the same boundary that a later `stabilize` call uses, so the
observed state is the state that the next caller meets.

The probe runs one control stabilization before fault injection. The control
proves that the harness alone does not change the phase.

The probe is on branch `prototype/eta-signal-atomic-entry` at commit
`c3642f3f`. One command runs it:

```sh
bash .scratch/prototypes/eta-signal-atomic-entry/run.sh
```

## Observed result

The command exits with status `0` and prints this record:

| Observation | Control | After forced overflow | After a later stabilization |
| --- | --- | --- | --- |
| `stabilize` exit | `Ok` | defect `Invalid_argument` | typed `Reentrant_stabilization` |
| phase | `idle` | `pure` | `pure` |
| pure-transaction status | none | active | active |
| transaction present | false | false | false |

The defect message is `Eta_signal_transaction: id overflow`.

## Analysis

N1 reproduces exactly. The escaped failure matches the static trace in the
independent review.

The graph mutates two phase fields before it allocates the transaction
identity. The allocator then raises, so the third field stays empty.

The pass-level `try` block starts after `begin_pure` returns. The public
`stabilize` path catches only `Graph_error` at that point. Therefore the
`Invalid_argument` exception escapes as a defect and no rollback runs.

The result is a permanent wedge, not a transient error. The phase stays `pure`
with an active status and no transaction, and each later `stabilize` returns
`Reentrant_stabilization` without changing that state.

Two public contracts break in this path. The typed error channel loses a
counter overflow to a defect, and the graph loses the idle state that a retry
needs.

## Identity comparison

The current identity is an integer from a module-global counter. That
representation carries two independent risks. Its allocator can fail at
`max_int`, and its mutable counter is shared by every graph in the process.

A fresh physical token removes both risks. The probe confirms that a `unit ref`
equals itself and differs from another fresh token, which is the complete
requirement for distinguishing pending cells. Such a token needs no counter and
no shared allocator.

Allocation of a physical token can still fail, because any allocation can raise
`Out_of_memory`. Therefore the representation change alone does not close the
defect.

The evidence identifies one required invariant instead. Identity construction
must complete before any phase field changes. Phase entry must then return a
pure token with a live transaction, or preserve the prior idle state exactly.

No observable state can hold `pure`, an active status, and no transaction.

## Limits

The probe runs one graph on one domain. It does not measure the cross-domain
race that a module-global counter allows.

The probe does not implement the production fix. The phase-model design, the
error name, and the identity representation belong to ticket 09.

The prototype-only setters and the phase snapshot exist on the prototype branch
only. They are not part of the shipped library.

## Census rows resolved

Executable reproduction settles these claim-census rows: `EXE-009`, `N01-002`,
`N01-003`, `N01-004`, `N01-005`, `N01-006`, `N01-007`, `N01-008`, `N01-009`,
`N01-011`, `N01-012`, `N01-013`, `N01-014`, `N01-029`, `S12-003`, and
`S14-001`.
