# Keyed signal operator contract

Type: prototype
Blocked by: 06, 07

## Question

What exact public operator does `eta_signal_map` publish for the Eta Crux
`Assoc` contract?

V1 contains one per-key operator. Prototype its name, module placement, type,
cutoff arguments, and construction callback.

The operator must consume an `Eta_signal_map.Map` signal and return the same map
type. It must update the previous output map instead of rebuilding it.

Prove that the operator preserves the structural keyed-child laws from
[Keyed assoc and stable child identity](../../eta-crux-first-principles/issues/04-keyed-assoc-contract.md).
The proof must cover data updates, removal, re-entry, rollback, lifecycle order,
and scope incarnations.

[Action injection and staged Eta effects](../../eta-crux-first-principles/issues/05-action-effect-protocol.md)
owns application delivery errors. [Dynamic lifetime and work ownership](../../eta-crux-first-principles/issues/07-dynamic-lifetime-ownership.md)
owns effect cancellation and lifecycle-hook values.

Decide how map diff equality and per-key publication equality interact. The map
must report every structural change that the operator needs for correctness.

For each physical `Changed`, compare the new map data with the currently
published child data. Do not compare only two consecutive raw map snapshots.
Cover a non-transitive cutoff where `A` equals `B`, `B` equals `C`, and `A` does
not equal `C`. In-place mutation of one physical data object remains
unobservable under the Eta Signal immutable-payload contract.

Compare the final shape with `Incr_map.mapi'`. Do not add another public keyed
operator during this ticket.

Keep the prototype on a throwaway branch. Link its behavioral checks and commit
from the answer.
