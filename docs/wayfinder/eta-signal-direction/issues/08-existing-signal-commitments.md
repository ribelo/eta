# Existing Signal and Eta Crux commitments

Type: task
Status: resolved
Blocked by: none

## Question

Which existing Eta Signal, Eta Signal Map, and Eta Crux commitments must this
effort confirm, amend, or replace?

Reconcile the Signal PRD, the kernel contract, ADR 0004, and package
requirements. Include the completed Eta Signal Map design map, both Eta Crux
maps, current public interfaces, and available SecondAgent implementation
evidence.

Identify contradictions and provisional statements. Separate consumer needs
from implementation choices. Treat external consumers as the primary source of
consumer value. Internal repository use is inventory, not a retention or
deletion rule. Internal absence cannot justify rejection or omission. Save a
concise commitment matrix under
`.scratch/research/eta-signal-direction/`.

## Answer

The sources establish consumer needs, but they do not form one final contract.
The durable needs are:

- Explicit stabilization with atomic pure publication and retryable updates.
- Demand-owned derived reads, dynamic scopes, and explicit observer disposal.
- Typed graph failures, Eta defects, and a clear post-commit effect boundary.
- Stable per-key child identity, same-key updates, removal, and fresh re-entry.
- A small Signal interface and an optional keyed collection capability.
- A graph-neutral Eta Crux interface with private engine types.
- One complete Eta Crux output after each atomic advancement.

The current implementation does not satisfy every recorded need. N1 and N2
break the atomic publication model. N3 breaks the PRD observer-order promise.
The PRD also disagrees with the public interface about stream domain ownership.
Tickets 09-13 own these Signal decisions.

ADR 0004 rejects a general application-facing graph extension. It does not
reject every first-party seam. The ADR selects a package-private protocol for
`eta_signal_map`, and the current implementation uses that protocol. Ticket 12
owns the final seam decision and claim-census row `Q06-001`.

The Eta Crux sources contain three incompatible directions. The old map selects
plain mutable state. The first-principles map selects a private Signal engine.
The old requirements pass a graph value to applications and batch actions.
Later first-principles decisions use graph-neutral descriptions and one message
per advancement.

The completed Signal Map design also replaces the provisional Crux keyed API.
It uses `Assoc(Order).assoc`, `data_cutoff`, and `Keyed(Order).mapi`. The
non-HEAD V1 bundle at `2ecc4f2f` still names `Stdlib.Map.S`, `data_equal`, and a
nonexistent public `Keyed_map` node. Ticket 14 owns the final Crux contract.

No production Eta Crux or inspectable SecondAgent implementation exists in the
repository refs or worktrees. The available Crux assets are design files and
throwaway prototypes. They provide scenarios, but they are not implementation
evidence.

The full matrix records each source, contradiction, disposition, and downstream
owner:

- [Existing Signal commitments](../../../../.scratch/research/eta-signal-direction/existing-commitments.md)

### Census rows resolved here

None. Ticket 08 owns no claim-census row. This answer supplies ADR evidence for
`Q06-001`, but Ticket 12 retains that row and its final disposition.
