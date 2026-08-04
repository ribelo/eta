# Engine and package seams

Type: grilling
Status: resolved
Blocked by: 06, 08, 09, 10

## Question

Where do the Eta Signal engine, Eta Signal Map, and any extension seam belong?

Decide whether the engine stays closed, exposes a narrow first-party protocol,
or gains another deep-module seam. Decide graph-functor ownership, the
two-graphs problem, package dependencies, version coupling, and the type-safe
testing surface.

The result must resolve F2, F7, F10, and ADR 0004. It must not expose phase,
scope, transaction, or graph-mutation complexity to application consumers.
Evaluate the seam for external application and library authors. The absence of
an in-repository node-kind package is not evidence against an externally useful
sealed protocol.
## Answer

**Status: resolved.**

Eta Signal exposes one **sealed, graph-branded stable-family protocol** for
library packages. It exposes no general custom-node or mutation API.

`Eta_signal.Make` remains the only graph factory. `eta_signal_map` adapts an
existing graph and never instantiates the engine.

The engine owns phase, transactions, scheduling, demand, topology, scopes,
invalidation, cleanup, and observer publication.

## One graph factory

A keyed application uses this construction shape:

```ocaml
module Signal = Eta_signal.Make (Observer_error) ()
module Signal_map = Eta_signal_map.Make (Signal.Package)
module Keyed = Signal_map.Keyed (Order)
```

`Signal.Package` is an opaque endpoint branded by that graph application.
`Signal_map` signals are type aliases of `Signal.signal`.

Applying `Eta_signal.Make` twice still creates incompatible graphs. Applying two
package adapters to one endpoint lets both adapters compose in one graph.

Eta adds no graph conversion, graph injection, compatibility functor, or second
factory. The current `Eta_signal_map.Make(Observer_error)()` shape is deleted.

## Sealed stable-family protocol

The endpoint exposes one abstract plan type, one stable-family plan constructor,
and plan installation. It exposes no open node-kind registration.

The public protocol has this exact shape:

```ocaml
module type Package_graph = sig
  type 'a signal
  type 'a plan

  type 'a change =
    | Left of 'a
    | Right of 'a
    | Changed of 'a * 'a

  type ('key, 'data, 'map) input_ops = {
    empty : 'map;
    compare_key : 'key -> 'key -> int;
    fold_symmetric_diff :
      'acc.
      'map ->
      'map ->
      on_compare:(unit -> unit) ->
      init:'acc ->
      f:('acc -> 'key -> 'data change -> 'acc) ->
      'acc;
  }

  type ('key, 'output, 'map) output_ops = {
    empty : 'map;
    set : 'key -> 'output -> 'map -> 'map;
    remove : 'key -> 'map -> 'map;
  }

  val stable_family :
    input:'data_map signal ->
    input_ops:('key, 'data, 'data_map) input_ops ->
    output_ops:('key, 'output, 'output_map) output_ops ->
    ?data_cutoff:(published:'data -> candidate:'data -> bool) ->
    build:(key:'key -> data:'data signal -> 'output signal) ->
    unit ->
    'output_map plan

  val install : 'a plan -> 'a signal
end
```

Each `Eta_signal.Make` result contains `module Package : Package_graph`.
Its `signal` type equals that graph's public signal type.

`Eta_signal_map.Make` accepts one `Eta_signal.Package_graph` module. Its result
contains `Keyed`, but it does not include the complete Signal interface.

`compare_key` defines a stable total order. Zero defines key identity. A retained
key cannot change its order.

`input_ops.empty` contains no binding. `fold_symmetric_diff` emits each changed
key once in increasing order and emits no unchanged physical data.

`Left` and `Changed` use the first-map key representative. `Right` uses the
second-map representative.

The diff calls `on_compare` once for each key comparison. It calls `f` once for
each emitted change and makes no later call after `f` raises.

The diff must report every addition, removal, and physical data change. The
engine validates event order and uniqueness, but completeness belongs to the
package adapter's law.

`output_ops.empty` contains no binding. `set` and `remove` preserve earlier
snapshots and obey `compare_key` identity.

`set` adds or replaces one binding. `remove` deletes one binding and returns the
same map after an absent-key removal.

The stable-family constructor accepts only:

- an input signal
- typed key comparison, symmetric-diff, and output-patch operations
- a directed data cutoff
- a child builder using ordinary signals
- typed output collection operations

The package creates immutable declarative plans. The engine interprets every
plan and creates the owner node.

The engine alone creates provisional children, scopes, edges, affected-child
indexes, staged cells, cleanup entries, and publication events.

The engine also performs prospective cycle validation, demand propagation,
frontier partitioning, rollback, and pure commit.

Package code cannot provide commit, rollback, cleanup, scheduling, invalidation,
or observer-delivery callbacks.

Package code cannot obtain a graph, node, edge, scope, phase, transaction,
scheduler, demand, queue, or mutation handle.

Diff, cutoff, and builder functions can fail only during planning. Ticket 09
rollback rules reject that attempt without partial publication.

Duplicate or contradictory family edits are planning defects. The engine rejects
them before it seals the mutation tape.

Adding another structural operation requires another closed plan form in an
Eta Signal release. It never uses an arbitrary registration callback.

## Why this seam is deep

A public mutation API transfers Eta invariants to every extension author. That
interface is shallow and permanently couples libraries to engine mechanics.

A closed engine avoids that transfer, but optional node packages become
alternative graph factories. Two such packages cannot compose.

The selected protocol exposes stable-family semantics only. It hides the
transaction, topology, demand, scheduling, and lifecycle machinery behind one
plan operation.

External libraries can build stable keyed sets, tries, grouped query results,
entity collections, and route collections without copying Eta's engine.

Libraries that need arbitrary dependencies, custom scheduling, raw invalidation,
or commit hooks cannot use this seam. They compose the public algebra instead.

This decision uses external library value as positive evidence. It does not use
repository consumer count as a gate.

## Package graph and versioning

The package graph is:

```text
eta

eta_signal -> eta, eta_observability, eta_stream
eta_signal_map -> eta_signal (= same release)
external stable-family package -> eta_signal (= same release)
```

The root `eta` package stays independent of both optional packages.
`eta_signal` stays independent of `eta_signal_map`.

The protocol belongs to the public `Eta_signal` result because each graph creates
its branded endpoint. No separate protocol opam package exists.

The engine implementation stays in private Dune libraries. Public CMIs name only
public Signal types and the abstract package protocol.

`eta_signal_map` stops depending on the private `eta_signal_kernel` library. It
compiles only against `eta_signal` and its stable-family protocol.

Exact release coupling remains mandatory for protocol consumers. Eta changes the
protocol and all first-party consumers in one release without compatibility
modules.

External protocol packages publish a matching release when Eta changes the plan
contract. Ordinary Signal libraries using only the algebra need no exact pin.

## F2 disposition

F2 is amended and resolved.

The current production keyed path is typed. It passes typed map and diff records
without `Obj`.

The current engine embeds keyed behavior and blocks separately linked node
packages. The new stable-family interpreter replaces that embedded special case.

Eta rejects a broad `Expert` API. It accepts one closed stable-family plan form
because the engine retains all dangerous authority.

The protocol provides useful external collection adapters. It does not support
arbitrary recompute nodes or expose internal scheduling contracts.

## F7 disposition

F7 is a private testing defect. It is not part of production `Keyed.mapi`.

`Keyed.Testing` remains repository-private. It is absent from the public
`Eta_signal_map` interface, and Eta publishes no testing package for it.

The universal `Obj.t` token and `Obj.magic` lookup are deleted. A creation-time,
typed family probe replaces lookup through an existential output signal.

The private plan installation returns an output signal and its typed probe to
test construction. Production installation discards the probe.

The probe keeps its key type and graph brand. Entry inspection therefore needs
no cast and cannot inspect another graph.

Entry snapshots use distinct opaque types for key, scope, source, data-signal,
child-signal, and edge identities. Events carry only a scope identity.

Typed equality accessors compare identities of the same role. `scope_valid`
accepts only a scope identity.

Misusing one identity role as another becomes a compile error. Public
`Keyed.mapi` retains its value-level signature.

## F10 disposition

F10 is removed by construction, not repaired with a warning.

`Eta_signal_map.Make` receives an existing graph-branded endpoint. It neither
accepts observer-error configuration nor applies `Eta_signal_kernel.Make`.

A package adapter cannot create a graph. Its operators return the existing
graph's signal type.

The old sole-map-factory rule is deleted. Applying `Eta_signal.Make` once is the
only valid graph construction rule.

Cross-graph signals and plans remain compile errors. No conversion exists.

## ADR 0004 disposition

ADR 0004 keeps these decisions:

- `eta_signal_map` is an optional sibling package
- root `eta` remains independent
- `eta_signal` has no collection dependency
- Eta publishes no broad graph extension API
- no separate kernel package exists

The ADR replaces its private cross-package kernel protocol with the sealed,
graph-branded stable-family protocol.

It also replaces the map-owned graph factory with adaptation of one existing
Signal graph. Exact release coupling remains part of the package contract.

ADR 0004 rejects broad graph authority, not every safe library-package protocol.
The selected seam preserves its safety rationale.

## Alternatives rejected

### Closed engine with sibling graph factories

This option keeps all engine details private. Each optional structural operator
must publish a complete replacement graph factory.

Reject it because independently useful packages cannot share one graph. A usage
warning does not remove that composition limit.

### Public graph mutation

This option offers maximum custom-node leverage. It exports phase, cycle, scope,
rollback, demand, and ordering hazards.

Reject it because this option gives library authors ownership of Eta's
invariants. Jane Street Incremental remains semantics evidence, not an API
target.

### General declarative custom nodes

This option hides direct mutation but freezes a general planning language for
arbitrary recompute behavior.

Reject it because such a language still exposes unstable scheduler and lifecycle
concepts. The stable-family form is narrower and has a complete semantic law.

## Evidence

- `lib/signal_map/api/eta_signal_map_api.ml:40-76` currently creates a second
  kernel and passes typed map and diff records.
- `lib/signal/kernel/eta_signal_kernel.ml:412-430,527-568` embeds keyed node state
  and map operations in the engine.
- `lib/signal/kernel/eta_signal_kernel.ml:3569-3715` exposes the private adapter
  and unsafe testing tokens.
- `lib/signal_map/eta_signal_map.mli:118-186` currently publishes the replacement
  graph factory and hides `Testing`.
- `lib/signal/kernel/dune:1-4` owns the private kernel library.
- `lib/signal_map/api/dune:1-4` records the private cross-package CMI dependency
  that this decision removes.
- `dune-project:50-60` records exact package coupling.
- [Ticket 09](09-transaction-and-invalidation-model.md#answer) defines the sealed
  plan, rollback boundary, and pure commit.
- [Ticket 10](10-scheduler-demand-and-topology.md#answer) defines engine-owned
  scheduling, demand, and topology mutation.
- [ADR 0004](../../../adrs/0004-lean-eta-signal-with-a-sibling-eta-signal-map.md)
  establishes the optional sibling and safety rationale.

## Census rows resolved here

Ticket 12 resolves all 62 assigned rows. F2 becomes a sealed-plan correction.
F7 becomes a typed private-probe correction. F10 loses the second graph factory.

### Resolution spans

| Census ID | Resolution span |
|---|---|
| EXE-002 | lines 221–222 |
| EXE-003 | lines 218–219 |
| F02-001 | lines 221–222 |
| F02-002 | lines 218–219 |
| F02-003 | lines 224–228 |
| F02-006 | lines 320–321 |
| F02-007 | lines 318–319 |
| F02-008 | lines 221–228 |
| F02-009 | lines 218–219 |
| F02-010 | lines 218–219 |
| F02-011 | lines 232–238 |
| F02-012 | lines 322–323 |
| F02-013 | lines 218–219 |
| F02-014 | lines 230–238 |
| F02-015 | lines 221–228 |
| F02-016 | lines 221–222 |
| F02-017 | lines 221–228 |
| F02-018 | lines 218–219 |
| F02-019 | lines 224–228 |
| F02-020 | lines 141–151 |
| F02-021 | lines 174–181 |
| F02-022 | lines 25–32 |
| F02-023 | lines 291–297 |
| F02-024 | lines 230–253 and 291–297 |
| F02-025 | lines 174–181 |
| F02-026 | lines 138–160 |
| F02-027 | lines 299–306 |
| F02-028 | lines 330–333 |
| F02-029 | lines 299–314 |
| F02-030 | lines 411–420 |
| F02-031 | lines 218–219 |
| F07-002 | lines 237–244 |
| F07-003 | lines 237–250 |
| F07-004 | lines 246–250 |
| F07-005 | lines 237–252 |
| F07-006 | lines 232–238 |
| F07-007 | lines 237–252 |
| F07-008 | lines 240–250 |
| F07-009 | lines 243–252 |
| F07-010 | lines 246–252 |
| F07-011 | lines 416–419 |
| F07-012 | lines 252–253 |
| F10-002 | lines 318–319 |
| F10-003 | lines 47–51 |
| F10-004 | lines 257–268 |
| F10-005 | lines 257–268 |
| F10-006 | lines 257–268 |
| F10-007 | lines 259–266 |
| F10-008 | line 268 |
| F10-009 | lines 257–268 |
| F10-010 | lines 259–266 |
| F10-011 | lines 257–268 |
| PLN-08-001 | lines 237–252 |
| PLN-08-002 | lines 246–252 |
| PLN-08-004 | lines 416–419 |
| PLN-09-001 | lines 257–268 |
| PLN-09-003 | lines 414–417 |
| DEF-001 | lines 162–181 |
| Q05-001 | lines 232–235 |
| Q05-002 | lines 237–252 |
| Q06-001 | lines 270–287 |
| Q06-002 | lines 280–287 |

## Implementation consequences

1. Make `Eta_signal.Make` the sole graph factory.
2. Add one graph-branded package endpoint with one closed stable-family plan form.
3. Move keyed lifecycle into the engine-owned stable-family interpreter.
4. Make `Eta_signal_map.Make` adapt the endpoint and preserve signal type aliases.
5. Remove `eta_signal_map`'s private kernel dependency and replacement factory.
6. Keep exact release coupling and publish no compatibility protocol.
7. Add external-package and cross-graph compile fixtures for the protocol.
8. Replace universal testing tokens with typed family probes and opaque identities.
9. Keep testing probes, fault injection, and counter mutation private.
10. Amend ADR 0004 and the keyed-extension requirements with this decision.
