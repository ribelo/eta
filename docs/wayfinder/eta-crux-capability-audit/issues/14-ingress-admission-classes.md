# Ingress admission classes

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does bounded Eta Crux ingress need explicit admission classes or isolation?

Check starvation and terminal-message loss across owner-domain sends, foreign
nonblocking sends, exported endpoints, and request resolution. Compare:

- root-wide FIFO admission.
- per-endpoint capacity.
- reserved guaranteed capacity.
- dropping or sliding admission.
- coalescing by endpoint.

Decide which policies Eta Crux can promise without inferring application
importance. Decide whether to adopt, defer with a precise condition, or reject
each policy.

For each accepted policy, specify its API shape, capacity accounting, ordering,
fairness, failure behavior, laws, test controls, transport equivalence, and
migration effects.

## Answer

### Decision

Adopt the existing root-wide bounded FIFO policy. Eta Crux adds no explicit
admission class or isolation API.

| Policy | Decision | Reason |
|---|---|---|
| Root-wide bounded FIFO | Adopt | One shared bound preserves action order. FIFO waiters prevent later nonblocking exports from overtaking a blocked send. |
| Per-endpoint capacity | Reject | Endpoint importance is application policy. Separate limits also make the unused capacity of one endpoint unavailable to another endpoint. |
| Reserved capacity | Reject | A reservation assigns importance to one action origin. Stop and crash already use a separate control path. |
| Dropping or sliding ingress | Reject | Dropping loses new actions. Sliding removes accepted actions. Producers and adapters own explicit lossy buffers before ingress. |
| Endpoint coalescing | Reject | Only the application knows whether one ingress action can replace another action. `Poll` suppresses stale results by request order, but it does not coalesce ingress. |

The rejected policies have no reopening condition. A later demand starts a new
decision effort with new consumer evidence.

### Evidence

The
[baseline report](../../../../.scratch/research/eta-crux-capability-audit/01-current-eta-crux-capability-baseline.md)
classifies admission classes as partial. Eta Crux supplies bounded FIFO ingress,
but it supplies no class API.

The [semantic laws](../../../design/eta-crux-v1/semantic-laws.md) already define
the important admission boundaries. Law A-02 gives waiting sends FIFO admission.
A later nonblocking export cannot overtake a waiting send.

`Source` sends items and terminal outcomes through the same owned endpoint path.
`Responder.resolve` completes a pending request through the request protocol. It
does not enqueue an application action. Stop and crash use the control path and
require no reserved ingress capacity.

No examined consumer demonstrates starvation while the root continues to
consume ingress. Consumer evidence also identifies no shared loss or coalescing
contract.

### Public API

Keep the public constructor unchanged:

```ocaml
val Root.create :
  ingress_capacity:int ->
  request_capacity:int ->
  'output description ->
  'output Root.t
```

Both capacities remain positive, explicit, and independent. Eta Crux adds no
default, admission-policy value, endpoint capacity, or reservation argument.

### Capacity accounting

- Each buffered application action uses one ingress slot.
- A waiting blocking send uses no buffered slot until admission.
- Payload size, endpoint identity, and transport do not change the slot count.
- Local endpoints, sources, exported endpoints, inbound request starts, Poll
  refreshes, and Poll completions share the ingress bound.
- Each Poll refresh and each Poll completion uses one ingress slot. They receive
  no reservation, priority, or separate capacity.
- An inbound request start needs one request slot and one ingress slot. Failed
  ingress admission releases the request slot.
- An outbound request uses request capacity and no ingress capacity.
- A pending request resolution uses no ingress capacity.
- Start, stop, crash, and other control events use no ingress capacity.

### Ordering and fairness

Accepted application actions share one FIFO order. One advancement consumes at
most one event, and control-event priority remains unchanged.

A blocking send that starts waiting gets FIFO position. Later blocking sends
join behind it. Later nonblocking export attempts cannot overtake it and return
`Full`.

Conditional progress requires the root to continue consuming ingress. The
sender must also remain live. Eta Crux promises no wall-clock latency and no
scheduler fairness before a sender joins the wait queue.

Source items and terminal outcomes use ordinary FIFO admission. A waiting source
terminal cannot lose its position to later nonblocking exports. Source disposal
interrupts its producer and creates no terminal action, as law S-05 specifies.

Poll refreshes and completions use ordinary FIFO admission. They keep request
order inside each Poll incarnation, but request order does not change ingress
order.

Root shutdown discards buffered application actions and closes waiting sends
with `Ingress_closed`. This terminal rule is not a lossy admission policy.

### Failure behavior

- `Endpoint.send` waits for capacity. It returns `Ingress_closed` when closure
  wins the admission race.
- `Exported_endpoint.try_invoke` never waits. It reports `Full` separately from
  `Ingress_closed` and export availability.
- `Request_export.invoke` reports request capacity, ingress capacity, ingress
  closure, and request closure separately.
- Admission returns no `Dropped`, sliding, replacement, or priority result.
- Endpoint incarnation remains an advancement check. A stale queued action is
  consumed and returns `Rejected Stale_endpoint`.
- Retained Poll refreshes and late Poll completions use the same stale-endpoint
  rule.

### Laws and test controls

The accepted policy keeps these existing laws and executable gates:

| Law | Required gate |
|---|---|
| A-01, acceptance appends one message | `test_endpoint_acceptance_boundary` |
| A-02, waiting sends get FIFO admission | `qcheck_ingress_fifo_admission` |
| A-03, closure and admission use first-winner arbitration | `race_ingress_close_vs_send_both_winners` |
| A-04, stale endpoints fail during advancement | `test_stale_endpoint_rejection` |
| A-05, `Endpoint.contramap` preserves admission | `qcheck_endpoint_contramap` |
| A-09, ingress and request bounds remain separate | `qcheck_capacity_bounds` and `qcheck_request_capacity` |
| T-01, application messages remain FIFO | `qcheck_one_event_advancement` |
| S-04 and S-05, source items and terminals use endpoint admission | `qcheck_source_latest_mapper` and `qcheck_source_terminal_outcome` |
| R-02, inbound capacity errors remain separate | `qcheck_request_capacity` |

[Latest-request-wins effect
coordination](21-latest-request-wins-effect-coordination.md) adds generated
coverage for Poll refresh and completion admission. It does not add an admission
class.

Tests use black-box production paths through roots, endpoints, exports,
requests, drivers, and transports. Eta Crux adds no queue-introspection API,
public queue statistics, or test-only admission controller.

### Transport equivalence

Local and serialized export invocations use the same root ingress after boundary
validation. Serialized transport can reject malformed handles, payloads, or
protocol frames before core admission.

After validation, both transports preserve acceptance, capacity-full results,
`Ingress_closed`, FIFO position, and closure behavior. The
`conformance_identity_serialized_equivalence` gate checks the shared production
contract.

### Migration effects

The decision changes no current public API or runtime behavior. Existing callers
need no migration.

The accepted `Poll` design adds refresh and completion items to the shared
accounting contract. It adds no capacity argument or admission-policy value.
Eta Crux adds no compatibility path.

Applications and adapters can keep upstream rate limits, bounded buffers, loss
policies, and latest-value models. These policies remain outside Eta Crux
ingress.
