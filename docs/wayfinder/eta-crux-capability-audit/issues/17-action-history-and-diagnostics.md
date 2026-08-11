# Action history and diagnostics

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does Eta Crux need bounded action history or stronger diagnostics?

Check the existing telemetry and failure-snapshot contracts. Separate bounded
committed-action diagnostics from replay, time travel, graph inspection, and
application-owned domain history.

Decide whether to adopt, defer with a precise condition, or reject each
diagnostic capability. If bounded history is adopted, specify enablement,
capacity, identity, redaction, retention, crash-report integration, ordering,
runtime cost, API shape, laws, test controls, ownership, and migration effects.

## Evidence

- [Reference evidence: action history and diagnostics](../../../../.scratch/research/eta-crux-capability-audit/17-reference-action-diagnostics.md)

## Answer

### Decision

Defer bounded committed-action history and non-retaining action observation.
Retain the current failure snapshots and fixed operational telemetry without
expansion.

Reject replay, time travel, and public graph inspection. Applications own
durable domain history. Eta observability owns any general bounded log-retention
sink.

No diagnostic capability enters the next Eta Crux implementation effort.

### Classification

| Capability | Decision | Reason |
|---|---|---|
| Bounded committed-action history | Defer | Eta Crux owns commit order and cell attribution, but no direct consumer demonstrates the diagnostic need. |
| Non-retaining action observer | Defer | Bonsai shows this tooling pattern, but no Eta Crux test or consumer requires it. |
| Current fatal action and model snapshots | Retain | Explicit hooks provide redacted context for a failing transition. |
| Current fixed operational telemetry | Retain | Payload-free categories report advancement and terminal outcomes without retained action data. |
| Additional fixed telemetry | Reject | The evidence identifies no missing operational signal. |
| Configurable diagnostic event stream | Reject | This surface adds ordering, failure, redaction, and callback contracts without a demonstrated need. |
| Replay from diagnostic records | Reject | Diagnostic records cannot recreate complete models, opaque effects, resources, or host state. |
| Time travel | Reject | Time travel is a debugger product with model checkpoints and replay semantics. |
| Public graph inspection | Reject | A graph schema exposes private topology and creates public structural identity. |
| Durable domain history | Reject Eta Crux ownership | Applications own business meaning, audit rules, persistence, and retention. |
| General bounded log-retention sink | Reject Eta Crux ownership | This capability belongs to Eta observability. |

No item receives an **Adopt** classification.

### Reopening condition

Reopen action observation and bounded committed-action history only when all
these conditions hold:

1. A direct Eta Crux consumer supplies a reproducible test failure or production
   incident.
2. Diagnosis requires the ordered prior commits and state-machine cell
   attribution that only Eta Crux owns.
3. Failure snapshots, fixed telemetry, Eta observations, and application or
   adapter logs cannot answer the question.
4. Application instrumentation requires private graph access or wrappers
   around every relevant action path.

The evidence must request diagnostic observation only. A request for replay,
time travel, or graph inspection requires a separate effort.

Reference presence does not satisfy this condition. Bonsai retains no applied
actions, and Rust Crux retains no processed events. Their test and development
tools emit or inspect current values without a retained production history.

Elm retains full message and model history only in `elm make --debug` browser
builds. Its unbounded history supports replay, import, and export. This debugger
does not establish a bounded Eta Crux production requirement.

### Existing diagnostic boundary

`State_machine.create ?diagnostics` remains optional. Its hooks run only after a
transition defect. They attempt to capture the failing action and the last
committed model. A failed hook leaves its snapshot absent and adds
`Crash_handler` evidence.

`Failure.t` retains local snapshots and ordered fatal records. The portable
failure form continues to omit action snapshots, model snapshots, cell
identity, and endpoint identity.

Operational telemetry remains the fixed payload-free logs, metrics, and spans.
It gains no action payload, model payload, observer callback, retained ring, or
new identity.

The current disabled-telemetry contract remains unchanged. Disabled telemetry
creates no observation state and changes no semantic result.

### Ownership

| Concern | Owner |
|---|---|
| Fatal transition snapshots and fixed Crux telemetry | Eta Crux |
| Effect execution, spans, causes, and observability capabilities | Eta |
| Generic log retention and sink policy | Eta observability |
| Domain events, audit history, persistence, and retention | Applications |
| Host diagnostics and reconciliation records | Adapters and providers |

### API, laws, cost, and migration

This decision adds no API, retained state, identity, queue, callback, law, test
control, package, or dependency.

The current failure, redaction, telemetry, wire, and disabled-instrumentation
gates remain authoritative. The next implementation effort adds no gate for this
deferred capability.

There is no migration. Existing diagnostic hooks, failure records, telemetry
names, and application-owned history remain unchanged.

This decision adds no Wayfinder ticket. The generic bounded log-retention sink
is outside the Eta Crux destination.
