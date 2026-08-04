# Operational introspection boundary

Type: grilling
Status: resolved
Blocked by: 05, 11, 12

## Question

What operational introspection belongs in Eta Crux V1 after typed actions,
failures, and the test contract are fixed?

Decide:

- which logs and metrics are production observations instead of test probes.
- whether action history exists outside explicit application diagnostics.
- whether any graph structure can be inspected without becoming public identity.
- whether time travel is possible without retaining models, effects, or host state.
- how redaction applies to actions, models, requests, and output.
- which observations belong to Eta, Eta Crux, a driver, or an adapter.
- which disabled instrumentation has zero semantic effect.

Do not expose private graph nodes only because internal law tests can inspect
them. Do not make a debugger or replay system part of V1 without a complete
state, effect, and host-boundary contract.

## Answer

### Boundary

Eta Crux V1 emits one fixed set of logs, metrics, and spans through
`eta_observability`. It exposes no observer callback or configurable event
stream.

Eta owns observations of effect execution, scopes, interruption, and resources.
Eta Crux owns observations of advancement and its structural protocol. The
driver owns protocol-handoff observations. An adapter owns observations of host
work and reconciliation.

Eta Crux retains no action history. It exposes no graph snapshot, node registry,
scope registry, model inspector, time travel, or replay facility. Applications
can record domain history and diagnostics explicitly.

### Effect boundary

Production driver operations that emit telemetry are typed-infallible Eta
effects. In particular, `Driver.poll`, delivery-token completion, request-event
completion, and serialized-session replacement return effects. `Driver.await`
remains an effect.

`Root.advance` is a typed-infallible Eta effect and emits no telemetry. It is the
low-level semantic operation for internal tests and the production driver.
Production integrations use `Driver` or `Hosted`.

The semantic changes to `Driver` include:

```ocaml
val poll :
  'output Driver.t ->
  ('output Driver.event option, Eta_crux.never) Eta.Effect.t

val delivered :
  'output Driver.Delivery.t ->
  ((unit, Driver.Delivery.completion_error) result, Eta_crux.never) Eta.Effect.t

val failed :
  'output Driver.Delivery.t ->
  Failure.Packed_cause.t ->
  ((unit, Driver.Delivery.completion_error) result, Eta_crux.never) Eta.Effect.t
```

The corresponding request-event answer operations and
`Driver.replace_serialized_session` have the same typed-infallible effect
boundary. `Driver.poll` performs available work but does not suspend.

### Logs

Eta Crux emits these fixed structured logs:

| Body | Level | Emission point |
|---|---|---|
| `eta_crux.root.started` | `Info` | The initial output is delivered and its post-commit batch returns `Admitted`. |
| `eta_crux.root.stopped` | `Info` | Normal root settlement is complete. |
| `eta_crux.root.crashed` | `Error` | The driver first emits crash detection. |

The crash log has these attributes when the failure supplies them:

- `eta_crux.failure.origin`
- `eta_crux.failure.trigger`
- `eta_crux.observation.position`

The values are closed category names or the root-local monotonic position. The
log contains no cause text, action, model, request, response, output, endpoint,
handle, cell identity, or graph identity.

### Metrics

Eta Crux emits only these V1 metric families:

| Name | Kind | Unit | Attributes |
|---|---|---|---|
| `eta_crux.advancements.total` | Monotonic counter | `{advancement}` | `eta_crux.trigger`, `eta_crux.outcome` |
| `eta_crux.advancement.duration` | Histogram | `ms` | `eta_crux.trigger`, `eta_crux.outcome` |
| `eta_crux.roots.terminal.total` | Monotonic counter | `{root}` | `eta_crux.outcome` |

`eta_crux.trigger` has the values `start`, `action`, and `control`.
`eta_crux.outcome` has only the values that apply to the instrument:

- Advancement: `committed`, `rejected`, or `failed`.
- Terminal root: `stopped` or `crashed`.

The advancement-duration boundaries are `0.01`, `0.025`, `0.05`, `0.1`,
`0.25`, `0.5`, `1`, `2.5`, `5`, `10`, `25`, `50`, `100`, `250`, `500`, and
`1000` milliseconds.

Idle polls and driver waits emit no telemetry. V1 emits no queue-depth, pending-request,
live-structure, or graph-size metrics. The reference frameworks do not provide
a comparable production contract. The evidence is in
[Operational metrics in Bonsai and Rust Crux](../../../../.scratch/research/eta-crux/operational-metrics-reference.md).

### Spans

Eta Crux emits these internal spans:

| Name | Operation |
|---|---|
| `eta_crux.advance` | One non-idle advancement. |
| `eta_crux.post_commit` | Admission or terminal settlement through a post-commit token. |
| `eta_crux.driver.delivery` | One output-delivery handoff and token answer. |
| `eta_crux.driver.request` | One request dispatch, response, or cancellation handoff and answer. |
| `eta_crux.session.replace` | One serialized-session replacement attempt. |
| `eta_crux.root.teardown` | Complete stop or crash teardown. |

Span attributes use bounded categories for operation kind and outcome. They can
also contain `eta_crux.observation.position`. They contain no root, node, cell,
endpoint, request, session, or handle identifier. Adapter work can create child
spans, but Eta Crux does not define those spans.

### Payloads and diagnostics

Framework telemetry never includes actions, models, requests, responses, or
root output. Fatal failure construction can call the explicit redacted action
and model hooks from [Failure, defect, and crash boundary](11-failure-boundary.md).
No other routine operation calls a diagnostic snapshot hook.

Applications and adapters own redacted diagnostics for requests, responses,
output, and host state. Local transport does not receive a more permissive rule
than serialized transport.

### Disabled instrumentation

Disabled instrumentation changes no result, ordering, scheduling, cancellation,
identity, failure, or driver event. It performs no snapshot encoding and retains
no observation state. Metric batches use lazy construction, so a disabled meter
does not build their attributes or points.

Valid telemetry capabilities are total. A capability that raises violates its
capability contract. Eta Crux does not suppress, translate, or attach such a
failure to the root.

[V1 performance gates](21-performance-gates.md) owns allocation and branch-cost
budgets for the disabled path.

### Stability

The names, levels, units, attribute keys, and closed attribute values in this
answer are part of the V1 operational contract. Later versions can add new
instruments or attributes. They cannot change the meaning of an existing name
or value without a contract change.
