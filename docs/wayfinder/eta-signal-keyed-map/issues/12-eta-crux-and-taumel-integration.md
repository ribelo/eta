# Eta Crux and Taumel integration

Type: prototype
Blocked by: 06, 08

## Question

What exact Eta Crux and Taumel API changes follow from the final map and keyed
operator contracts?

Produce compile-checked `.mli` and call-site sketches. Do not implement either
consumer.

The Eta Crux sketch must replace the provisional `Assoc (M : Stdlib.Map.S)`
contract. It must keep the settled graph-neutral computation description and
keyed-child laws.

The sketch must mark action delivery, effect cancellation, and lifecycle-hook
payloads as dependencies on their named Eta Crux decisions. This ticket does
not resolve those application protocols.

The Taumel sketch must build and update an agent map through ordinary persistent
operations. It must exercise insertion, data update, removal, and keyed output
consumption.

Use the sketch to find missing map operations. Do not add convenience operations
without a concrete call site.

State all required consumer changes and all unaffected APIs. Link the sketches
and prototype commit from the answer.
