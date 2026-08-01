# Eta Signal extension seam

Type: prototype
Status: resolved
Blocked by: 05, 06

## Question

What minimum Eta Signal capability lets `eta_signal_map` install one
transactional keyed node without exposing general graph internals?

The current graph, scope, bind, and transaction modules are private to the
`eta_signal` library. A sibling library cannot call them directly. Prototype the
smallest package and module seam that solves this constraint without a circular
dependency.

Show how the seam supports:

- one graph instance and its generative signal type
- provisional keyed scopes and stable per-key data sources
- dependency attachment and removal
- preflight, commit, and rollback of structural edits
- removal before addition during commit
- scope invalidation and stale-incarnation rejection
- demand and observer reachability

The public `Eta_signal` facade must not gain a graph value, scope handle, raw
node constructor, or broad `Expert` module.

Compare an internal capability module, a shared kernel library, and a narrow
extension functor. Include Dune dependency sketches and negative type examples.

Keep the prototype on a throwaway branch. Link its sketches and commit from the
answer.

## Answer

Use a package-private signal kernel and a closed `Eta_signal_map` factory.
Do not publish a graph capability or an extension adapter.

The `eta_signal` package owns a private `Eta_signal_kernel` library. Dune
installs this library below the package `__private__` path. Ordinary downstream
packages cannot name it.

Both public libraries use the kernel:

- `Eta_signal.Make` exposes only the current Eta Signal interface.
- `Eta_signal_map.Make` exposes that interface and the keyed operator.

The second library depends on `eta_signal` at the same package version. The
dependency keeps the private kernel and the public facade in one release unit.
The public CMIs do not name the kernel.

The selected public shape is:

```ocaml
module Make (Observer_error : Eta_signal.Observer_error) () : sig
  include module type of Eta_signal.Make (Observer_error) ()

  module Keyed (Order : Map.Ordered_type) : sig
    module M : module type of Map.Make (Order)

    val create :
      ?data_equal:('data -> 'data -> bool) ->
      'data M.t signal ->
      f:(key:M.key -> data:'data signal -> 'out signal) ->
      'out M.t signal
  end
end
```

Ticket 08 owns the final operator and argument names. This ticket fixes the
factory boundary and the type relationships.

An existing `Eta_signal.Make` graph cannot gain keyed support. A caller that
needs keyed signals creates the graph through `Eta_signal_map.Make`. Eta Crux
owns this selection in `Root.create`, so applications do not select the factory.

## Internal protocol

The private keyed node owns these values:

- the last raw input map
- one entry for each committed key
- the persistent output map
- one scope incarnation, data source, and child signal in each entry

Planning uses the committed input as the diff base. It stages an accepted data
update before it computes retained children. The first correct implementation
computes every retained child. Ticket 11 must prove an optimization before the
public contract makes a change-proportional claim for child computation.

Each addition gets a provisional scope. Planning registers that scope for
rollback before it runs the builder. The child stays detached from the keyed
owner and committed demand roots until commit.

Global preflight uses owner-before-descendant order. It refreshes the complete
removal closure after each plan. If an outer removal owns a nested plan,
preflight excludes that plan and invalidates its provisional scopes.

The private transaction gains a `preflighted` phase. Preflight closes staging
and completes all fallible work. The total pure commit then performs these
actions:

1. Detach and invalidate all planned removals.
2. Attach all planned additions.
3. Publish the staged cells and computed snapshots.
4. Mark the collected observer events pending.
5. Update necessity from the committed graph.

Timer effects, cleanup effects, and observer callbacks run after the
irreversible pure commit. Their failure does not roll back the committed
snapshot.

No production signal code uses the current transaction hook APIs. Remove the
unused preflight, commit, and rollback hooks when the transaction gains its
phase type.

A removed key invalidates the exact scope in its entry. A later equal key gets
a new scope, data source, child graph, and signal identity. The existing scope
validity check rejects a captured signal from the old incarnation.

The keyed node depends on the input and each committed child output. These edges
participate in compute order, reachability, timer demand, and diagnostics.

## Rejected seams

A public internal capability exposes raw scope, edge, invalidation, staging,
commit, rollback, and demand operations. Ordinary code can use every forbidden
operation, so this seam is too broad.

A narrow extension functor must accept a structural map adapter because
`eta_signal` cannot depend on `eta_signal_map`. Ordinary code can supply an
incomplete diff adapter. The prototype shows that this adapter loses an
addition and still compiles.

## Prototype and validation

Prototype commit: `d7bcbaab` on `prototype/eta-signal-extension-seam`.

The prototype includes positive Dune sketches and these negative type checks:

- a signal from another graph does not type-check
- a child from another graph does not type-check
- a map from another key order does not type-check
- graph, scope, and dependency primitives are absent from public CMIs
- an external package cannot name the installed private kernel

The complete prototype passed:

```sh
bash .scratch/prototypes/eta-signal-extension-seam/run.sh all
```

This command passed on OxCaml `5.2.0+ox` and mainline OCaml `5.4.1`. An
independent code review and an independent architecture review returned PASS.
