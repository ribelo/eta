# Keyed signal operator contract

Type: prototype
Status: resolved
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

## Answer

### Public interface

Publish one operator named `Keyed(Order).mapi`:

```ocaml
module Make (Observer_error : Eta_signal.Observer_error) () : sig
  include module type of Eta_signal.Make (Observer_error) ()

  module Keyed (Order : Map.Ordered_type) : sig
    val mapi :
      ?data_cutoff:
        (published:'data -> candidate:'data -> bool) ->
      'data Map.Make(Order).t signal ->
      f:(key:Order.t -> data:'data signal -> 'output signal) ->
      'output Map.Make(Order).t signal
  end
end
```

`mapi` takes the input before `~f`. The map type uses the direct applicative
`Map.Make(Order).t` path.

`Keyed(Order)` does not expose a map type alias or a nested map module. A
separate application of `Map.Make(Order)` has the same map type.

The operator has no `~equal`, `~data_equal`, `~cutoff`, `~output_equal`, or
caller-supplied diff adapter. V1 publishes no second keyed operator.

### Data cutoff

`data_cutoff` controls data publication for a retained key. It defaults to this
physical-identity predicate:

```ocaml
fun ~published ~candidate -> published == candidate
```

The map diff remains physical-only and never accepts this predicate. The keyed
node calls `data_cutoff` only for a physical `Changed` event on a retained key.

A `true` result retains the current published data. A `false` result stages the
candidate in the existing data source. Additions and removals never call the
predicate.

The predicate does not need symmetry or transitivity. Its labeled arguments
define the direction.

The keyed node keeps three different committed snapshots:

- the last raw input map
- the data currently published to each child
- the persistent output map

For each `Changed`, compare the candidate with the published child data. Do not
compare it only with the old raw-map value.

For the non-transitive `A`, `B`, and `C` case, the first transition compares
`A` with `B`. If it suppresses `B`, published data remains `A`.

The next transition compares `A` with `C`, even though the raw input advanced to
`B`. Thus, it publishes `C` when the predicate rejects `A` and `C`.

If `data_cutoff` raises, Eta treats the exception as a defect. Pure planning
rolls back before the defect escapes, and a retry can call the predicate again.

In-place mutation of one physical data object remains unobservable. This limit
follows the Eta Signal immutable-payload contract.

### Builder and child identity

The builder receives a constant key and one stable per-key data signal. It
returns one child signal from the same graph.

The builder must be pure, total, and synchronous. It runs for provisional
additions only and can run again after rollback.

Continuous key presence preserves these identities:

- the stored key representative
- the keyed scope and incarnation
- the data source and data signal
- the child signal and dependency
- child-local graph state

An accepted data update stages the existing data source. It does not run the
builder or replace the child.

A committed removal invalidates the stored keyed scope. Later re-entry creates
a fresh scope, data source, child graph, and incarnation.

Changes before one stabilization collapse to the final input snapshot. A
transient removal and re-entry does not create a lifecycle edge.

Commit detaches and invalidates all removals before it attaches any addition.
Rollback keeps committed removal candidates live and invalidates provisional
additions.

### Output publication

The keyed node starts each output plan from the previous output map. It uses
persistent `Map.set` and `Map.remove` edits.

An addition sets one binding. A removal removes one binding. A published child
change sets its binding.

The keyed node also observes child changes that have no input-map change. Such a
change patches only the affected output binding.

The operator has no aggregate output cutoff. Each child signal owns its output
cutoff.

A suppressed data update, a child no-op, and rollback retain the prior output
root. The implementation must not rebuild output with `of_list`.

Ticket 11 owns the complete complexity statement. The first correct keyed node
can compute all retained children and makes no change-proportional child-work
claim.

### Incr_map comparison

`Incr_map.mapi'` has two input gates. Its `data_equal` filters consecutive raw
maps, and its `cutoff` controls each per-key data node.

Eta keeps only the second semantic gate. Its map diff is always physical, and
`data_cutoff` compares published data with candidate data.

Eta adopts stable per-key data nodes, child invalidation, and persistent output
patching from the reference behavior. It does not adopt the broad operator
suite or expert-node transaction model.

The reviewed Incr_map source is commit
`21c6bc602c75d57242b4c3e945da597f82c6280f`. The prototype does not copy its
source.

### Prototype and validation

Prototype commit: `ac4b2782` on `prototype/eta-signal-keyed-operator`.

Run the complete prototype with:

```sh
bash .scratch/prototypes/eta-signal-keyed-operator/run.sh all
```

The prototype compiles the selected interface and two rejected map-type
surfaces. Nine expected compiler rejections protect the selected boundary.

The behavioral model has 11 Alcotest cases. One case runs 1,000 deterministic
QCheck traces with seed `[| 0x455441; 0x4b4559; 0x4d4150 |]`.

The command passes on OxCaml `5.2.0+ox` and mainline OCaml `5.4.1`. Manual
contract and code review passes found no blocker. The user disabled new review
agents for this prototype, so validation does not include a separate agent
review.

Action delivery errors, effect cancellation, and lifecycle-hook payloads remain
with their named Eta Crux decisions.
