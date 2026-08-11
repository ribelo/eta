# Coherent accepted capability surface

Type: grilling
Status: open
Blocked by: 08, 09, 10, 11, 12, 13, 14, 15, 16, 17, 20, 21

## Question

Do the accepted capability designs form one coherent Eta Crux surface?

Check all adopted, deferred, and rejected decisions together. Remove duplicate
concepts and contradictory ownership. Preserve Bonsai graph semantics, Rust Crux
host boundaries, and Elm API simplicity. Preserve Eta effect ownership unless a
recorded decision changes that boundary.

Specify cross-capability interactions, shared terms, public module placement,
law dependencies, test-control composition, migration order, and documentation
changes. Update this ticket's blocking list when
[Complete capability relevance census](08-complete-capability-relevance-census.md)
creates additional candidate tickets.

Do not prescribe internal implementation steps.

## Reopened findings

[Audit coverage closure](19-audit-coverage-closure.md) found three accepted
contracts without complete law and test-gate specifications:

- Exclusive driver attachment and `Driver_attached` behavior have no law or
  named gate.
- Concurrent movement of one shared test clock has no arbitration owner or
  two-winner gate.
- Concurrent destructive observer reads have no law or named gate.

The next resolution must remove these contracts or specify their law ownership,
test controls, and named executable gates.

## Answer

### Result

The accepted decisions form one coherent Eta Crux surface after the
reconciliations in this answer.

The surface keeps one graph model, one ingress queue, one commit fence, one
driver owner, and one shell-request protocol. It adds no command algebra,
streaming request, admission class, host-operation layer, or graph-inspection
surface.

### Capability classification

All nine reported claims were factually correct. No claim was incorrect.

| Reported capability | Baseline state | Final decision |
|---|---|---|
| Graph time and deterministic clock control | Missing | Adopt `Time` and deterministic handle controls. |
| External graph input | Application-composable | Reject a separate input path. Use typed endpoint Actions. |
| Startup facts and flags | Application-composable | Reject a distinct capability. Use typed construction dependencies. |
| Staged-effect observation | Partial | Adopt explicit effect absence and the post-commit observer. |
| Host-owned streaming operations | Deliberately excluded | Reject many-response requests. Use `Source` and provider dependencies. |
| Ingress admission classes | Partial | Retain one bounded FIFO queue. Reject classes, reservations, loss, and coalescing. |
| Pull observation of root output | Partial | Adopt `Driver.latest_committed_output`. |
| Host-operation layers | Application-composable | Reject layers. Adopt corrected one-shot handler claims. |
| Action history and diagnostics | Deliberately excluded | Defer action observation and bounded history. Reject replay, time travel, and graph inspection. |

The complete census also produced two adopted capabilities:

- [Structural model reset](20-structural-model-reset.md) adds scoped, atomic
  reset of active descendant models.
- [Poll run result coordination](21-poll-run-result-coordination.md) adds
  graph-owned Poll runs with a hidden run order.

The action-observation deferral keeps the reopening conditions from
[Action history and diagnostics](17-action-history-and-diagnostics.md). No
other capability is deferred.

### Shared terms

The accepted surface uses these terms:

| Term | Meaning |
|---|---|
| **Action** | A typed input to one live state-machine cell. |
| **Ingress item** | One value accepted by the root ingress queue. |
| **Message** | A shell-boundary envelope. It does not name a cell Action. |
| **Poll run** | One effect execution started by a Poll. It is not a shell request. |
| **Request** | One framework-owned, one-shot exchange across the shell boundary. |
| **Root output** | The complete application value from one successful commit. |
| **Latest committed output** | The Root output from the greatest completed commit. |
| **Latest delivered output** | The last Root output whose delivery token the host accepted. |

Actions, reset triggers, Poll refreshes, and Poll completions are ingress-item
classes. Each class uses the same capacity and FIFO rules.

`Failure.Endpoint_message` becomes `Endpoint_action`. Poll terminology uses
`run`, `run order`, and `run history`. Poll laws and diagnostics do not use
`request` for this concept.

### Ownership

| Concern | Owner |
|---|---|
| Effect execution, scheduling, interruption, scopes, finalizers, clocks, and sleeps | Eta |
| Graph time, active deadlines, clock sampling, and driver wakes | Eta Crux |
| Actions, ingress, structural reset, Poll run order, and commit publication | Eta Crux |
| Shell requests, handler claims, and request settlement | Eta Crux |
| Latest committed-output retention | `Driver` |
| Successful-delivery state and host reconciliation | Adapters |
| Post-commit observation types and observer attachment | `Eta_crux.Testing` |
| Post-commit observer controller and destructive reads | `eta_crux_test` |
| Models, builders, Poll inputs, cutoffs, result values, and domain policy | Applications |
| Host registration, operation routing, buffers, retries, and provider diagnostics | Adapters and providers |

Graph time does not use `Eta_signal.Time`. Eta Signal keeps its generic timer
contract. Eta Crux owns its own graph-time contract because its driver owns
deadline wake behavior.

### Public module placement

`eta_crux` adds these top-level modules:

- `Time` for graph monotonic time and deadlines.
- `Reset` for scoped structural reset authority.
- `Poll` for change-driven and manual Poll runs.
- `Testing` for shared observer types and one opaque observer attachment.

The modules do not sit under a capability umbrella. `Time`, `Reset`, and
`Poll` are computation modules beside the existing computation surface.

`State_machine.create` changes transition effects from a mandatory effect to:

```ocaml
'model * (unit, never) Eta.Effect.t option
```

Its optional reset callback uses the same effect shape. `None` means that the
callback stages no effect.

`Root.create` accepts this optional test attachment:

```ocaml
?post_commit_effect_observer:Testing.post_commit_effect_observer
```

`Driver` adds:

```ocaml
val latest_committed_output : 'output t -> 'output option
```

`Request.Driver_event` uses these result shapes:

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

val dispatch :
  t ->
  'error handler ->
  (dispatch_result, 'error) Eta.Effect.t

val handle :
  t ->
  ('request, 'response) Host_operation.t ->
  f:
    ('request ->
     resolve:
       ('response ->
        ((unit, not_pending) result, never) Eta.Effect.t) ->
     on_cancel:((closure_reason -> unit) -> unit) ->
     (unit, 'error) Eta.Effect.t) ->
  (handle_result, 'error) Eta.Effect.t
```

Descriptor identity defines a handler match. The first matching handler claims
the event before it runs. A typed handler failure retains that claim.

`eta_crux_test` adds `Post_commit_effect_observer`. The controller re-exports
the shared observer types from `Eta_crux.Testing`.

`Handle.create` and `Handle.use` require an explicit
`Eta_test.Test_clock.t`. `Handle.last_output` is removed and replaced with:

```ocaml
val latest_committed_output :
  ('output, 'incoming) t -> 'output option

val latest_delivered_output :
  ('output, 'incoming) t -> 'output option
```

The remaining accepted API shapes stay in their capability tickets. Rejected
and deferred capabilities add no public module.

### Root and Driver ownership

One unstarted root accepts one `Driver` attachment. The attachment gives that
driver sole authority to advance the root.

`Driver.create`, `Handle.create`, and `Handle.use` raise `Invalid_argument` for
a started or attached root. `Driver.create` also rejects a reused binding.

Direct `Root.advance` on a driver-owned root returns:

```ocaml
Error Driver_attached
```

`Driver_attached` joins `Root.advance_error`. This rejection consumes no ingress
item, reads no clock, and records no observer event.

### Ingress and event selection

The root keeps one positive, explicit ingress capacity. Every buffered ingress
item uses one slot.

After initial start, event priority is:

1. crash or stop.
2. `Clock_due`.
3. the next FIFO ingress item.

Reset triggers, Poll refreshes, and Poll completions receive no priority,
reservation, or separate queue. Poll run order does not change ingress order.

An inbound request start still requires one request slot and one ingress slot.
An outbound request still uses request capacity without using ingress capacity.

### Commit and observation order

One successful advancement has this observable order:

1. The root atomically publishes the complete committed frame.
2. An attached observer records `Staged`.
3. `Root.advance` returns `Committed`.
4. The driver publishes `latest_committed_output`.
5. The driver exposes the matching `Deliver` event.
6. Delivery acceptance admits the post-commit batch.
7. Eligible effects record `Started`.

The committed frame includes model changes, graph structure, deadlines, Poll
state, reset results, Root output, and the exact observed effect inventory.

A pull reads the latest committed output. It does not answer a delivery token,
start post-commit work, or change the latest delivered output.

Every successful commit records one `Staged` event when an observer is
attached. The event contains:

- zero or one transition effect.
- zero or more reset effects.
- one effect for each Poll run that the commit starts.

The list has no structural or execution order. Transition, reset, and Poll-run
effects form one concurrent post-commit class.

The post-commit observer has one destructive consumer. Concurrent `poll`,
`drain`, or `expect_empty` calls raise `Invalid_argument`.

### Time, Reset, and Poll interactions

Moving a test clock changes time for every root that uses that clock. The move
does not advance any root.

Two overlapping handle movements on one clock are invalid. One movement wins,
and the other raises `Invalid_argument`.

A later `frame`, `drain`, `poll`, or `await` observes due clock work through the
production driver. A `Clock_due` commit can change a Poll input and start one
Poll run.

One structural reset uses one FIFO ingress item. Every callback sees the same
pre-reset committed frame.

Reset reconciliation can activate, dispose, or change a Poll input. The same
commit can inventory reset effects and Poll-run effects.

If a reset callback raises, the complete advancement rolls back. The failure
record identifies the callback that raised.

The reset interface publishes no traversal order. Therefore, it publishes no
stable winner when more than one callback can raise.

Each active Poll incarnation owns one hidden monotonic run order. The result
with the greatest committed run order is current.

A newer started but incomplete run does not suppress an older completed run. A
later completion with a greater run order replaces that older result.

A valid stale completion commits an unchanged Root output. A completion from a
disposed incarnation receives the ordinary stale-endpoint rejection.

Poll runs use no shell-request identity, request slot, response token, or wire
frame. Shell requests remain one-shot host exchanges.

### Failure integration

The accepted surface adds these failure and root variants:

- `Graph_clock` in `Failure.origin`.
- `Clock_sample`, `Clock_due`, `Structural_reset`, and `Poll_effect` in
  `Failure.trigger_kind`.
- `Stale_reset` in `Root.delivery_error`.
- `Driver_attached` in `Root.advance_error`.

It renames `Failure.Endpoint_message` to `Endpoint_action`.

Poll run-order exhaustion raises:

```text
Invalid_argument "Eta_crux: poll run order overflow"
```

The capability tickets define clock, reset, Poll, and handler failure
attribution. This reconciliation adds no fallback, silent conversion, or
untyped error path.

### Law ownership and dependencies

Existing law IDs remain stable. Their text changes where the accepted surface
supersedes the old contract.

The registry adds these law families:

- `GTC-*` for graph time and deterministic clock control.
- `RST-*` for structural reset.
- `POLL-*` for Poll runs and result selection.
- `PCO-*` for post-commit effect observation.

Shared semantic claims have one normative owner:

| Law family | Shared ownership |
|---|---|
| `A-*` | Ingress capacity, admission, FIFO order, closure, and stale Actions. |
| `T-*` | Atomic commit publication and post-commit phase order. |
| `L-*` and `S-*` | Active intervals, disposal, keyed incarnations, and Sources. |
| `R-*` | Shell-request identity, handler claims, cancellation, and settlement. |
| `D-*` and `O-*` | Driver publication, delivery, pull observation, and output retention. |
| `H-*` | Handle ownership, clock movement, output boundaries, and explicit test controls. |

Capability laws reference these shared laws. They do not restate FIFO, commit,
delivery, or lifecycle contracts.

Graph-time laws own `Clock_due` eligibility and its priority integration. Reset
and Poll laws reference shared ingress laws.

Observer laws own mixed effect inventory. Driver and observation laws own the
ordering between `Staged`, latest output, `Deliver`, and effect start.

The named executable gates from the capability tickets remain required. Poll
gate names use the canonical run-order term.

### Test-control composition

Tests compose explicit controls. Eta Crux adds no umbrella test context.

A test that observes effects uses this order:

1. Create `Post_commit_effect_observer`.
2. Pass its attachment to `Root.create`.
3. Pass an explicit test clock and the unstarted root to the handle.
4. Use controlled dependencies for calls, completion, cancellation, and
   scheduler control.
5. Use handle operations for production-driver advancement.

Tests can share one clock across handles. Each root still advances only through
its own handle.

`Controlled_source` remains the Source control. Controlled effect providers
remain the Poll control. The post-commit observer records framework-owned
staging and lifecycle.

### Direct replacement and documentation

There are no Eta Crux consumers to migrate. The accepted surface replaces the
current contract directly.

There is no public migration sequence, compatibility API, transitional
overload, default clock, or consumer migration plan. Internal implementation
order is not part of this decision.

The implementation effort changes public interfaces, canonical design, laws,
tests, codecs, fixtures, and repository callers together.

The canonical replacement updates:

- `docs/design/eta-crux-v1/README.md` for modules, ownership, and exclusions.
- `docs/design/eta-crux-v1/public-api.md` for the complete production and test
  surfaces.
- `docs/design/eta-crux-v1/semantic-laws.md` for revised and new law families.
- `docs/design/eta-crux-v1/verification.md` for controls, gates, and performance
  checks.
- `docs/design/eta-crux-v1/wire-protocol.md` for changed portable enums and
  fixtures.
- `CONTEXT.md` for the shared domain terms.

Graph time, Reset, Poll, and the observer add no wire-frame family. Portable
failure variants still require codec tags and fixture updates.

The direct replacement preserves the accepted Bonsai graph semantics, Rust
Crux host boundary, Elm-style flat surface, and Eta effect ownership.
