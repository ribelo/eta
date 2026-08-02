# Eta Crux integration boundary

Type: prototype
Status: claimed
Blocked by: 06, 08

## Question

What exact Eta Crux API changes follow from the final map and keyed-operator
contracts?

Produce a compile-checked public `.mli` and private interpreter sketch. Do not
implement Eta Crux or the signal-map bridge.

The public sketch must replace the provisional `Assoc (M : Stdlib.Map.S)`
contract. It must keep the graph-neutral computation type and all settled
keyed-child laws.

Use `Eta_signal_map.Make` and `Keyed(Order).mapi` in the private interpreter.
Decide whether the Eta Crux wrapper keeps `Assoc(Order).assoc` or adopts the
substrate name. Also decide whether its provisional `data_equal` argument
becomes the directed `data_cutoff` name.

Mark action delivery, effect cancellation, and lifecycle values as dependencies
on their named Eta Crux decisions. This ticket does not change those protocols.

State all required Eta Crux changes and all unaffected Eta Crux APIs. Downstream
applications are transitive consumers. Do not use their current implementation
choices as requirements for this boundary.

Link the sketches and prototype commit from the answer.
