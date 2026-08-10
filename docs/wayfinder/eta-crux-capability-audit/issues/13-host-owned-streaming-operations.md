# Host-owned streaming operations

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does Eta Crux need a host-owned operation that can resolve many times?

Check the current composition of `Source`, `Host_operation`, `Requester`, and
exported endpoints for process output, file watching, server-sent events,
websockets, and host lifecycle events.

Compare a many-response host operation, a source bound to a host adapter, and the
current application-wired composition. Decide which layer owns desired-set
reconciliation, item admission, completion, failure, cancellation, and stale
emissions.

Decide whether to adopt, defer with a precise condition, or reject the
capability. If adopted, specify the API shape, semantic laws, backpressure,
test controls, transport behavior, ownership, and migration effects.

## Answer

### Decision

Reject a many-response `Host_operation`. Eta Crux keeps one-shot host
operations and the existing `Source` contract.

This rejection rests on duplicate semantic ownership and public-surface cost.
The limited consumer evidence is not itself a rejection reason.

Eta Crux adds no binding API between `Source` and `Adapter.resource`. An
integration supplies host-specific producers as ordinary typed dependencies.

### Accepted composition

The computation graph defines the desired set of active sources. Structural
presence defines lifetime. `Source.spec_cutoff` defines continuity for one
declaration. `Assoc` defines keyed source sets.

A provider installs the concrete host registration for one source producer. A
same-process provider can register a callback that calls `emit`. A foreign
provider composes the existing endpoint, request, adapter, and transport
surfaces.

Eta Crux does not standardize the foreign provider protocol. The provider must
preserve the `Source` outcomes at the graph boundary.

The representative scenarios use this composition:

- Process output uses one `Source`. Output items become actions, and process
  completion or failure becomes a terminal outcome.
- File watching uses the watched set as the source specification. A material
  specification change creates a fresh source incarnation.
- Server-sent events and websockets use one source per connection or logical
  subscription. The provider owns connection and reconnect policy.
- Repeated host lifecycle facts use a source when the graph consumes them.
  `Adapter.resource` and `Hosted.run` still own the adapter-binding lifetime.

### Ownership

| Concern | Owner and rule |
|---|---|
| Desired-set reconciliation | Graph structure, `Source`, and `Assoc` own source identity, continuity, replacement, and removal. |
| Host registration | The provider installs and removes callbacks, watchers, process readers, or network subscriptions. |
| Item admission | `Source.emit` uses ordinary endpoint admission. The bounded root ingress queue applies FIFO admission and backpressure. |
| Provider buffering | The provider owns its upstream buffer, capacity, and overflow policy. Eta Crux adds no per-source queue. |
| Completion | Normal producer completion creates one `Completed` terminal action. Eta Crux does not restart the source. |
| Typed failure | An opening or producer failure creates one `Failed` terminal action. The provider defines transport errors and reconnect policy. |
| Defects | An escaping defect follows the existing root crash boundary. |
| Cancellation | Structural disposal interrupts the producer. Eta finalizers perform provider cleanup. Disposal creates no terminal action. |
| Stale emissions | An old queued action is consumed and reported as `Rejected Stale_endpoint`. It performs no transition. |
| Transport | Providers use the existing local or serialized surfaces. Eta Crux adds no many-item request frames. |

### Alternatives

A many-response host operation duplicates source identity, cancellation,
terminal, stale-item, and backpressure rules. It also requires new request
cardinality, wire frames, test controls, and transport-equivalence laws.

A public source-to-adapter binding adds a second source lifecycle. Ordinary
typed producer dependencies already connect a source to host code.

The current application-wired composition remains the accepted shape. Provider
packages can hide repeated host code without changing the Eta Crux core.

### Contract effects

The public API and wire protocol do not change. One-shot law R-01 remains in
force.

Existing laws A-02, A-04, A-09, L-03, L-04, and S-01 through S-05 define the
complete framework contract. Per-class admission remains a separate decision in
[Ingress admission classes](14-ingress-admission-classes.md).

`Eta_crux_test.Controlled_source` remains the test control for opening, item
emission, completion, typed failure, cancellation, and stale-emitter scenarios.
Provider tests own concrete host transport and buffer behavior.

This decision adds no migration work. It also adds no new ticket or map fog.
