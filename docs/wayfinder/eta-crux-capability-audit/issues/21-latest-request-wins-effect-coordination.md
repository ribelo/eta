# Latest-request-wins effect coordination

Type: grilling
Status: resolved
Blocked by: 08

## Question

Does Eta Crux need a graph-owned protocol that prevents stale asynchronous
effect results from changing the current model?

Compare application sequence tokens, cancellation on replacement, and a
framework-owned generation or result guard. Keep basic change-triggered effects
as application-composable.

Decide whether to adopt, defer with a precise condition, or reject the
capability. If adopted, specify the API shape, request identity, ordering,
out-of-order completion, child disposal, and same-key reincarnation. Also
specify cancellation, failure behavior, semantic laws, test controls, ownership,
and migration effects.

## Answer

### Decision

Adopt a graph-owned `Poll` computation with Bonsai latest-request-wins
semantics.

`Poll` starts work on activation, significant input changes, or manual refresh.
It stores the newest committed result by request order. Applications continue
to own other change-triggered effects and coordination policies.

The relevant Bonsai evidence is in the
[public capability census](../../../../.scratch/research/eta-crux-capability-audit/bonsai-public-capability-census.md).
Bonsai owns change detection, request order, and stale-result suppression.
Eta Crux adopts those transferable semantics through its own commit and
lifecycle protocols.

The three compared mechanisms have these results:

| Mechanism | Decision | Role |
|---|---|---|
| Graph-owned Poll | Adopt | Start effectful requests and prevent an older committed completion from replacing a newer one. |
| Application sequence tokens | Retain | Express domain-specific ordering outside `Poll`. |
| Cancellation on replacement | Reject | A newer request does not cancel an older request in the same active Poll incarnation. |

### Public API

Add this module to `eta_crux`:

```ocaml
module Poll : sig
  type 'a computation := 'a t

  module Starting : sig
    type ('result, 'output) t

    val empty : ('result, 'result option) t
    val initial : 'result -> ('result, 'result) t
  end

  val effect_on_change :
    input_cutoff:'input Cutoff.t ->
    ?result_cutoff:'result Cutoff.t ->
    starting:('result, 'output) Starting.t ->
    input:'input computation ->
    effect:
      ('input -> ('result, never) Eta.Effect.t) computation ->
    unit ->
    'output computation

  val manual_refresh :
    ?result_cutoff:'result Cutoff.t ->
    starting:('result, 'output) Starting.t ->
    effect:(('result, never) Eta.Effect.t) computation ->
    unit ->
    'output computation
    * (unit, Endpoint.admission_error) Eta.Effect.t computation
end
```

The final `unit` arguments make the optional `result_cutoff` arguments erasable
under OCaml labelled-argument rules.

`Starting.empty` publishes `None` before the first accepted result. Each
accepted result is published as `Some result`.

`Starting.initial result` publishes that value before the first accepted result.
Later accepted results have the same result type.

The default `result_cutoff` is `Cutoff.phys_equal`. The cutoff controls result
propagation. It does not control request order.

### Automatic polling

`effect_on_change` starts one request when its Poll incarnation activates. It
uses the latest input and provider from that successful commit.

After activation, `input_cutoff` compares the prior committed active input with
the candidate input. A suppressed candidate starts no request.

One advancement starts at most one automatic request for one Poll node. Multiple
changes during stabilization coalesce into the latest committed input.

A provider change alone starts no request. A triggering commit captures the
latest provider. Eta Crux invokes that provider only when the request starts.

A failed stabilization commits no Poll state and starts no Poll effect.

Inactive Poll nodes keep no input or provider history. Reactivation starts one
request with the latest activation-frame values.

A `Clock_due` advancement can change a Poll input and trigger one request. Moving
test time without a driver advancement does not trigger Poll.

### Manual refresh

`manual_refresh` returns the result computation and one computed refresh effect.
Each invocation of the refresh effect requests one separate Poll run.

The refresh effect uses ordinary blocking FIFO ingress. It returns
`Ingress_closed` when root closure wins admission.

Each accepted invocation uses one ingress slot. Repeated invocations remain
separate and never coalesce.

Admission does not promise later processing. A retained refresh effect for a
disposed Poll can enter ingress. Its advancement returns
`Rejected Stale_endpoint`.

A successful refresh advancement captures the current provider, assigns the
next request order, and stages one Poll effect. Automatic and manual requests
share one request order.

### Request identity and order

Each active Poll incarnation owns one hidden monotonic request order. The
application and test APIs expose no request identity or sequence token.

Each successful triggering commit assigns the next request order. The order
defines request priority even when the Eta scheduler starts bodies in another
order.

Request order never wraps or repeats within one incarnation. Exhaustion raises
`Invalid_argument "Eta_crux: poll request order overflow"`.

The root records exhaustion with `origin = Transition` and the current
advancement trigger. The complete advancement rolls back, and no Poll effect
starts.

`Poll` does not serialize request bodies. A later request does not cancel,
interrupt, or wait for an earlier request in the same active incarnation.

### Completion and result selection

When a Poll body returns, Eta Crux submits one hidden endpoint action through
ordinary blocking FIFO ingress. Completion admission uses one ingress slot and
gets no priority or reserved capacity.

A request is complete for result selection when its hidden action commits. The
effect return alone does not make its result current.

The Poll state keeps the greatest committed request order and its result. A
completion changes the result only when its request order is greater than the
stored order.

For requests A then B, A can publish while B remains incomplete. A later B
completion replaces A.

If B commits first, a later A completion cannot replace B. The stale completion
still performs one successful advancement and commits an unchanged root output.

A newer equal result advances the stored request order. `result_cutoff` can
suppress dependent propagation, but it cannot remove this order fence.

A stale completion does not call `result_cutoff`. Completion-action FIFO order
does not change the request-order comparison.

If root closure wins completion admission, Eta Crux discards the result during
normal shutdown. The Poll body then has no result action to process.

### Commit and post-commit order

A successful trigger commit publishes its complete root output before the Poll
body starts.

The post-commit batch registers all new work behind closed gates. It then
requests cancellation for removed scopes and opens new sources.

After the existing lifecycle phase, Eta Crux releases application transition,
structural-reset, and Poll effects as one concurrent class. Eta Crux publishes
no start or settlement order within that class.

The next advancement cannot start before the driver admits the complete
post-commit batch.

### Disposal and reincarnation

Poll disposal closes the Poll incarnation before it requests cancellation of
all active Poll bodies. Cancellation does not wait for body or finalizer
settlement.

Completion and disposal have two legal winners. A completion action ahead of
the disposal action in FIFO can commit its result first.

If disposal wins, queued or later completion actions cannot change Poll state.
They can produce the normal `Stale_endpoint` rejection.

Re-entry creates a fresh Poll incarnation. This rule also applies to removal and
re-entry of the same `Assoc` key.

The new incarnation restores its starting output. It has fresh endpoint
identity, request order, input history, and provider history.

An old completion can never enter the new incarnation.

### Failure behavior

Poll bodies have type `('result, never) Eta.Effect.t`. Applications convert
expected failures into result values before they return from the body.

An escaping defect follows the existing owned-work crash protocol. Add
`Poll_effect` to `Failure.trigger_kind`.

A provider exception at Poll-body start uses `origin = Owned_work` and
`trigger = Poll_effect`. A later body defect uses the same attribution.

Interruption-only disposal remains normal cleanup. It does not create a Poll
failure.

An input-cutoff or result-cutoff exception occurs during graph advancement. It
uses the existing transition failure protocol, commits no partial Poll state,
and starts no effect from that failed commit.

### Post-commit effect observation

Rename the accepted `Transition_effect_observer` to
`Post_commit_effect_observer`. Rename its attachment SPI, root argument, and
executable gates with it.

The observer covers these effects:

- application transition effects.
- structural-reset effects.
- Poll request effects.

It continues to exclude lifecycle programs, source openings, source producers,
requests, and adapter work.

A Poll request appears in the exact effect inventory of its triggering commit.
It follows the existing started-and-settled or discarded-before-start path.

A hidden Poll result action creates its own successful commit. That commit
records its own effect inventory, including a downstream Poll that it triggers.

A stale endpoint rejection consumes no commit index and records no staged
event.

### Test controls and executable laws

Eta Crux adds no Poll-specific test controller. Tests use controlled effect
providers, normal test frames, and `Post_commit_effect_observer`.

The implementation effort adds these laws and named gates:

| Law | Generated class and observation boundary | Gate |
|---|---|---|
| Each incarnation publishes its selected starting output and has empty request history. | Generated graphs cover static children, `bind` replacement, `Assoc` removal, and same-key re-entry with both starting forms. The boundary is committed root output, provider-call witnesses, and stale driver events from old completions. | `qcheck_poll_starting_incarnation` |
| A successful activation stages one request after delivery. One advancement stages at most one automatic request with the latest committed input. | Generated advancements include endpoint actions, resets, clock events, multiple candidate changes, and failed stabilization. The boundary is committed output, provider-call witnesses, and post-commit observer events. | `qcheck_poll_activation_and_coalescing` |
| `input_cutoff` alone decides whether an active candidate input triggers work. Inactive candidates create no history. | Generated cutoffs include `always`, `never`, physical equality, and value equality across active and inactive intervals. The boundary is cutoff-call witnesses, provider-call witnesses, and committed output. | `qcheck_poll_input_cutoff` |
| Each request uses the provider from its triggering commit. A provider-only change does not trigger work. | Generated provider replacements occur before automatic triggers, before refreshes, and without a trigger. The boundary is labelled provider-call witnesses and committed output. | `qcheck_poll_provider_sampling` |
| Each refresh invocation appends one ordinary FIFO item or returns `Ingress_closed`. Refreshes never coalesce. | Generated roots vary capacity, refresh count, closure timing, and Poll disposal. The boundary is refresh admission results, driver events, provider-call counts, and committed output. | `qcheck_poll_manual_refresh_admission` |
| Completion actions share bounded FIFO ingress with application actions, and one advancement consumes at most one item. | Generated interleavings include endpoint actions, refreshes, and two or more completions under full and available capacity. The boundary is admission witnesses, driver frames, and committed outputs. | `qcheck_poll_completion_fifo` |
| A completion changes output only when its order exceeds every prior committed completion order. | Generated incarnations start two to five requests and execute every completion permutation. Each run forces a newer-before-older witness. The boundary is controlled completion order and committed outputs. | `qcheck_poll_latest_request_wins` |
| A newer equal completion advances the order fence even when result propagation is suppressed. | Every generated case forces newer-equal completion, then older-different completion, then one later completion. The boundary is result-cutoff calls and committed outputs. | `qcheck_poll_result_cutoff_order_fence` |
| Request order is strict and never reused within one incarnation. A new incarnation starts a fresh order. | Generated runs vary request count, completion permutation, disposal, and same-key re-entry. The boundary is result selection, committed outputs, and stale driver events. | `qcheck_poll_request_order` |
| Request-order exhaustion rolls back the complete advancement and records a transition failure with the active trigger. | A white-box generator constructs private Poll models at the final valid orders and the exhausted state. It dispatches endpoint, clock, reset, and refresh triggers through the production Poll transition. The boundary is root failure, prior output, provider-call witnesses, and observer events. This gate adds no public test control. | `qcheck_poll_request_order_overflow` |
| Completion and disposal admit both legal winners. Disposal-first requests cancellation without waiting and fences every old result. | Generated children cover static, `bind`, and `Assoc` incarnations with completion on each side of disposal. The boundary is output, driver events, cancellation witnesses, observer events, and final fiber census. | `race_poll_completion_vs_disposal_both_winners` |
| Output delivery precedes Poll start. Transition, reset, and Poll effects have no relative start or settlement order. | Controlled commits stage each effect source alone, transition with Poll, and reset with Poll. Every body waits at one barrier. The gate observes all starts before release, then forces settlement order to differ from inventory order. The boundary is delivery and observer events. | `test_poll_post_commit_phase_order` |
| A Poll body cannot expose a typed error. | Negative compile fixtures cover both Poll constructors with one typed-error body each. The boundary is the compiler result and expected type-error span. | `poll_effect_rejects_typed_error` |
| Poll defects use `Owned_work` and `Poll_effect`, while interruption-only disposal creates no failure. | Generated defects occur during provider invocation and body execution. Disposal cases force interruption-only settlement. The boundary is failure records, observer events, and final fiber census. | `qcheck_poll_failure_attribution` |
| The observer inventories each Poll request in its triggering commit and records one lifecycle path. | Generated Poll-only and mixed commits force success, interruption, failure, out-of-order settlement, and discard before start. The boundary is the exact observer trace and controlled provider witnesses. | `qcheck_post_commit_effect_observer_poll_lifecycle` |
| Clock-event priority remains ahead of FIFO ingress when a clock commit triggers Poll. | Generated roots make `Clock_due`, queued ingress, and a Poll input change eligible together. The boundary is driver-frame order, provider-call witnesses, and committed output. | `qcheck_poll_clock_priority` |
| Identity and serialized drivers produce the same Poll behavior after boundary validation. | Generated actions, refreshes, and completion schedules run through both bindings. The boundary is admission results, driver events, provider calls, and committed outputs. | `qcheck_poll_transport_equivalence` |
| A graph without Poll allocates no Poll state, request order, endpoint, hook, observer identity, or observer event. | The disabled-path benchmark covers initial start, equal actions, changing actions, resets, and clock events. The boundary is exact allocation counters and the existing latency threshold. | `poll_disabled_allocation` |

Generated failures print graph structure, incarnations, inputs, request orders,
provider selections, cutoff decisions, admission outcomes, ingress order,
disposal winners, effect events, and root outputs.

Tests without valid background work finish with an empty fiber census.

The disabled-path benchmark uses the existing disabled-telemetry threshold. It
requires equal per-action allocation and no more than a 5% median regression in
two of three comparisons.

### Ownership and cost

Eta Crux owns Poll incarnation, request order, trigger coalescing, provider
sampling, result selection, ingress integration, cancellation requests, and
post-commit observation.

Applications own Poll placement, inputs, cutoffs, providers, starting values,
typed failure values, and use of accepted results.

Eta owns effect execution, scheduling, interruption, finalizers, and controlled
test dependencies.

Poll state is node-local. Its live cost follows active Poll nodes and in-flight
requests. A graph without Poll keeps the capability path inert.

### Migration

`eta_crux` adds `Poll` and `Failure.Poll_effect`. Existing graph code requires no
change unless it adopts Poll.

The observer decision changes from `Transition_effect_observer` to
`Post_commit_effect_observer`. Its attachment SPI, `Root.create` argument, test
controller, and gate names change together.

The observer inventory expands from application transition and reset effects to
application transition, reset, and Poll effects.

The ingress decision adds Poll refresh and completion items to root-wide
capacity accounting. It adds no class, reservation, priority, or coalescing.

Exhaustive matches, portable failure codecs, telemetry labels, and wire fixtures
must add `Poll_effect`.

The implementation effort updates public interfaces, semantic laws, executable
gates, verification text, canonical design documents, and repository callers
together.

There is no compatibility alias, fallback path, or silent conversion.
