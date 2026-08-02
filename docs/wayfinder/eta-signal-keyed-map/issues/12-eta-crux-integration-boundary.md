# Eta Crux integration boundary

Type: prototype
Status: resolved
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

## Answer

### Public Eta Crux interface

Keep `Assoc(Order).assoc` as the Eta Crux composition word:

```ocaml
module Assoc (Order : Eta_signal_map.Map.Ordered_type) : sig
  val assoc :
    ?data_cutoff:
      (published:'data -> candidate:'data -> bool) ->
    'data Eta_signal_map.Map.Make(Order).t t ->
    f:(key:Order.t -> data:'data t -> 'output t) ->
    'output Eta_signal_map.Map.Make(Order).t t
end
```

`assoc` names keyed composition in Eta Crux. `mapi` names the substrate
operation in Eta Signal. The different names keep the public computation layer
separate from its interpreter.

`Assoc` takes the ordered key module. It does not take a `Stdlib.Map.S` module.
The input and output use the direct applicative `Map.Make(Order).t` path. The
wrapper does not expose a second map alias.

Rename `data_equal` to `data_cutoff`. The function compares the published value
with a candidate value. A true result keeps the published value. A false result
publishes the candidate. The default remains physical identity.

This type change preserves all keyed-child laws from Eta Crux ticket 04. It also
preserves all map and operator laws from tickets 06, 08, and 10.

### Private interpreter mapping

Eta Crux creates its roots with `Eta_signal_map.Make`. The private interpreter
maps `Assoc(Order).assoc` directly to `Signal.Keyed(Order).mapi`.

The interpreter forwards `data_cutoff` without a change to its argument order or
meaning. `eta_signal_map` owns the structural transaction, affected-child
notification, and persistent output-map patches.

The public Eta Crux interface exposes no signal type, graph value, scope value,
or `Keyed` module.

### Required Eta Crux changes

1. Replace `Assoc(M : Stdlib.Map.S)` with `Assoc(Order : Map.Ordered_type)`.
2. Replace `M.t` with `Eta_signal_map.Map.Make(Order).t`.
3. Rename `data_equal` to `data_cutoff`.
4. Create roots with the `Eta_signal_map.Make` graph factory.
5. Compile `Assoc(Order).assoc` through `Keyed(Order).mapi`.
6. Remove the provisional `Stdlib.Map.S` interpreter path.

Do not add a conversion from `Stdlib.Map`. A conversion severs ancestry and
keeps an obsolete compatibility path.

### Unaffected Eta Crux APIs

This decision does not change these Eta Crux APIs:

- graph-neutral computation descriptions
- roots and advancement semantics
- state machines and endpoints
- dynamic composition
- lifecycle descriptions
- root output and host observation

Eta Crux ticket 05 owns the action-delivery protocol. Eta Crux ticket 07 owns
effect cancellation and lifecycle values. This decision does not add payloads
or hooks to those protocols.

Downstream applications are transitive consumers. Their current implementation
choices do not constrain this boundary. This ticket makes no downstream
migration commitment.

### Prototype and validation

Prototype commit: `59bf8b81` on branch
`prototype/eta-signal-map-integration`.

Run the prototype with:

```sh
bash .scratch/prototypes/eta-signal-map-integration/run.sh all
```

The command passes on OxCaml `5.2.0+ox` and mainline OCaml `5.4.1`. It compiles
both naming candidates and the private mapping. Negative checks reject the old
`data_equal` label, a `Stdlib.Map` input, and public `Assoc.mapi`.

The public `.mli` leak check and unsafe-escape-hatch check pass. The user
disabled new review agents, so validation used direct self-review.
