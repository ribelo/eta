# Host-operation layers

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does Eta Crux need composable layers over host operations?

Check whether `Request.Driver_event.handle` and `Different_operation` already
form a complete semantic chain. Examine repeated work for redaction, logging,
recording, retries, partial handling, and forwarding to another shell.

Separate cross-cutting host-operation composition from application retry policy.
Decide whether to adopt, defer with a precise condition, or reject a layer
abstraction.

If adopted, specify the API shape, ordering, short-circuit behavior, typed error
and cancellation rules, laws, test controls, ownership, and migration effects.

## Answer

### Decision

Reject a first-class host-operation layer abstraction. Adapters and providers
own operation routing and cross-cutting wrappers.

The layer candidate is **Reject**. The one-shot dispatch correction enters the
next implementation effort.

Keep `Request.Driver_event.handle` as a selective operation matcher. Keep
`Request.Driver_event.dispatch` as the total eliminator for generic adapters.
These functions are dispatch primitives, not a layer chain.

The next implementation effort must correct their one-shot contract. This
correction does not add a layer abstraction.

### Evidence

The
[current capability baseline](../../../../.scratch/research/eta-crux-capability-audit/01-current-eta-crux-capability-baseline.md)
records the current primitives and the explicit middleware exclusion. The
[decision history](../../../../.scratch/research/eta-crux-capability-audit/02-prior-decision-and-requirement-provenance.md)
confirms that the exclusion is deliberate.

The
[consumer audit](../../../../.scratch/research/eta-crux-capability-audit/07-representative-consumer-friction.md)
finds no external Eta Crux consumer. Repository callers use one matcher and
treat `Different_operation` as an assertion failure. No caller composes a
multi-operation fall-through chain.

The current implementation has three contract gaps:

- `handle` can run the same matching handler after prior handling or settlement.
- `dispatch` has no result that reports a prior handler claim or closure.
- No semantic law covers matching, fall-through, or handler-claim finality.

Fixed Eta Crux telemetry already excludes operation payloads. The existing
request path performs no automatic retry or request replay.

### Corrected dispatch surface

The corrected semantic shape is:

```ocaml
type dispatch_result =
  | Dispatched
  | Already_handled
  | Closed of closure_reason

type handle_result =
  | Handled
  | Different_operation
  | Already_handled
  | Closed of closure_reason
```

`dispatch` returns `dispatch_result`. `handle` returns `handle_result`.

One driver event has an atomic handler claim. This claim is separate from
dispatch acknowledgment and response resolution.

`handle` first compares the operation descriptor. A mismatch returns
`Different_operation`, runs no handler, and does not claim the event.

The first matching `handle` or total `dispatch` claims the event before it runs
the handler. A later matching `handle` or `dispatch` returns
`Already_handled` and runs no handler.

A typed handler failure retains the claim. The adapter cannot fall through to
another handler after a matched provider fails.

If cancellation closes the event before the claim, a matching `handle` or
`dispatch` returns `Closed reason`. It starts no host work.

If the claim wins first, cancellation uses the installed `on_cancel` path. The
callback receives the exact closure reason.

### Adapter composition

An adapter can call selective matchers in its declared order. It continues only
after `Different_operation`. It stops after every other result.

If all matchers return `Different_operation`, `request_event` must fail with an
adapter error. The adapter must not accept an unmatched event. `Hosted.run`
converts this failure to the existing `Dispatch_failed` result and request
dispatch failure record.

A generic adapter can use `dispatch` instead. Its polymorphic handler must
handle the supplied operation or fail with its typed adapter error.

Eta Crux defines no wrapper order, partial-handler product, next-handler
callback, or forwarding layer.

### Ownership

| Concern | Owner and rule |
|---|---|
| Operation selection | The adapter owns its supported operation set and matcher order. |
| Provider wrapper | The adapter or provider owns operation-specific wrappers. |
| Expected operation failure | The application protocol carries it in the typed response value. |
| Application retry | The application wraps `Requester.request` with Eta effects. |
| Provider retry | A provider can retry only inside its host implementation. |
| Dispatch failure | Eta Crux retains `Dispatch_failed` and request-dispatch failure reporting. |
| Transport forwarding | The driver owns local or serialized delivery. |
| Shell replacement | The driver closes pending requests. It does not replay or transfer an event. |
| Logging and redaction | Adapters and providers own operation-specific policy. Eta Crux telemetry remains fixed and payload-free. |
| Recording | Tests or providers own operation records. `Eta_crux_test.Recording_adapter` remains an event recorder. |

### Laws and test controls

The next implementation effort must add named executable laws for these rules:

1. A nonmatching selective handler does not run and does not claim the event.
2. At most one matching handler or total handler starts for one event.
3. A typed handler failure retains the handler claim.
4. Handler claim and cancellation use first-winner arbitration.
5. Cancellation that wins before the claim starts no host work.
6. Fixed Eta Crux telemetry exposes no operation request or response payload.

The generated handler law must use distinct operation descriptors. It must
exercise matching, mismatch, prior claim, closure, and typed failure.

The race test must force both claim and cancellation winners. It must prove the
handler count, the closure reason, and the final request result.

An adapter test must exhaust all selective matchers. It must prove that the
final mismatch becomes `Dispatch_failed`.

The existing driver-event surface, `Test_shell`, and controlled adapter tools
are sufficient. No new test-control abstraction is necessary.

### Migration effects

The next implementation effort changes the result types of `handle` and
`dispatch`. It must update:

- `eta_crux.mli` and the matching implementation.
- the public API document and semantic-law registry.
- all in-repository handler call sites and request tests.
- the request race and telemetry gates.

No known external Eta Crux consumer requires migration. The change adds no wire
frame, codec, package, dependency, operation registry, or compatibility shim.

### Rejected alternatives

A layer stack adds ordering, short-circuit, error, cancellation, and replay
contracts without direct consumer evidence.

Removing `dispatch` prevents a generic adapter from eliminating the existential
driver event through one typed handler.

A framework `Unhandled_operation` error duplicates the supported-operation
policy of the adapter.

Automatic Crux retry combines dispatch lifecycle with application failure
policy. Forwarding an event to another shell breaks its root ownership and
one-shot settlement.

This decision adds no ticket or map fog.
