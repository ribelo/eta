---
kind: issue
requirements:
  - gtc-8dib
  - gtc-lmpw
  - gtc-oi4p
  - gtc-qakh
  - gtc-apbp
  - gtc-xdt8
  - gtc-o4ni
  - gtc-5um9
  - gtc-3ip9
  - gtc-o4qv
  - gtc-7ucg
  - gtc-9cmj
  - gtc-610f
  - gtc-ep7p
  - gtc-trme
  - gtc-ws0o
  - gtc-t43r
  - gtc-w6yj
  - gtc-bi1g
  - gtc-gpx8
  - gtc-eib6
  - gtc-laxo
  - gtc-5heu
  - gtc-kuwm
  - gtc-v8ym
  - gtc-a8mx
  - gtc-75bf
  - gtc-hezs
  - gtc-hw7q
  - gtc-k3ft
  - gtc-ed08
  - gtc-fbmn
  - gtc-70nf
  - gtc-eb47
  - gtc-a8z6
  - gtc-2huo
  - gtc-bnro
  - gtc-ldhe
  - gtc-vg5h
  - gtc-9a8f
  - gtc-iyvf
  - tcl-fcar
  - tcl-12dq
  - tcl-rnv4
  - tcl-eevg
  - tcl-u0dd
  - pco-oaz8
  - pco-ryjt
  - pco-4g4s
  - pco-b9dv
  - pco-bhjt
  - pco-9j7p
  - pco-rkuf
  - pco-iyga
  - pco-4zp9
  - pco-jtck
  - pco-mfbx
  - pco-vz5b
  - pco-j13u
  - pco-6awr
  - pco-702c
  - pco-yben
  - pco-lc7w
  - pco-hxm6
  - pco-d7v2
  - pco-0m14
  - pco-yq4f
  - pco-m6gy
  - pco-n9h7
  - drv-2kde
  - drv-vnzs
  - drv-88a3
  - drv-ezg1
  - drv-7534
  - drv-mr88
  - drv-uz8j
  - drv-1ae6
  - drv-nh43
  - drv-xuol
  - drv-q32x
  - drv-mp5h
  - drv-e5gt
  - dsp-fxzm
  - dsp-pfj0
  - dsp-ugx2
  - dsp-xu36
  - dsp-o8gq
  - dsp-rs4f
  - dsp-uwt9
  - dsp-e9ri
  - dsp-6ehp
  - ing-siq4
  - ing-z6vw
  - ing-83wu
  - ing-8y37
  - ing-fst5
  - rst-rly9
  - rst-nc0b
  - rst-y2eh
  - rst-5d9i
  - rst-eibt
  - rst-2rb8
  - rst-hzdm
  - rst-e7oy
  - rst-vm9q
  - rst-kefj
  - rst-4rxh
  - rst-onh3
  - rst-1045
  - rst-mkos
  - rst-ymrr
  - rst-djex
  - rst-qbhv
  - rst-lytj
  - rst-7mzq
  - rst-3ayr
  - rst-6rcx
  - rst-t7ic
  - rst-3edb
  - poll-b3e0
  - poll-u0yw
  - poll-sy8h
  - poll-1xxp
  - poll-tki5
  - poll-e841
  - poll-3cl9
  - poll-ed0r
  - poll-36nx
  - poll-m5lf
  - poll-2j0r
  - poll-5nhm
  - poll-drcw
  - poll-fxv8
  - poll-uyga
  - poll-jd9s
  - poll-iv1r
  - poll-4ian
  - poll-qp48
  - poll-b6b9
  - poll-seh9
  - poll-59po
  - poll-nb95
  - poll-ertk
  - poll-a64q
  - poll-jer9
  - poll-ec08
  - poll-lbow
  - poll-5bgb
  - poll-cdus
  - poll-pd9d
  - poll-bctg
  - poll-uaev
  - poll-6psq
  - poll-ef4p
  - fwire-h69w
  - fwire-q41u
  - fwire-m1ly
  - fwire-4jpr
  - surf-zgy1
  - surf-9rhv
  - surf-se1m
---

# Eta Crux capability surface

## Problem Statement

An Eta Crux application author cannot express a value that changes with time
inside the graph. The graph has no clock, a deadline cannot wake the blocking
driver, and a test cannot move time deterministically. Each application
rebuilds time handling from Eta effects, and those effects cannot wake
`Driver.await`.

A test author cannot assert which effects a commit staged, whether a
transition staged nothing, or whether a staged effect started, settled, or was
discarded. Tests rebuild counters, promises, and polling loops per case and
still cannot attribute overlapping effects to exact commits.

A host author must cache pushed deliveries to read the latest application
state. No linearizable pull exists. Adapter authors get no final handler
claim: a matching request handler can run after prior handling, and `dispatch`
cannot report a prior claim or closure.

An application author resets a subtree of state machines only through
per-cell reset Actions or keyed remounts, and suppresses stale asynchronous
poll results only through hand-built sequence tokens.

The driver, the test clock, and test observers also have unspecified races:
exclusive driver attachment, concurrent test-clock movement, and concurrent
observer reads have no arbitration owner.

The
[Eta Crux capability audit](../../wayfinder/eta-crux-capability-audit/map.md)
verified all nine reported gaps as factually correct, censused 71 reference
capability families, and resolved 11 candidate decisions. This spec turns the
seven adopted designs and their reconciliation into the implementation
contract.

## Solution

Implement the reconciled accepted Eta Crux capability surface as a direct
replacement of the current contract:

- `Eta_crux.Time`: graph monotonic time with `now`, `deadline`, `after`, and
  `interval`, driver deadline wakes, and deterministic test-time control.
- `Eta_crux.Reset`: scoped, atomic reset of active state-machine descendants.
- `Eta_crux.Poll`: graph-owned change-driven and manual effect runs. The
  result with the greatest committed run order is current.
- Explicit effect absence through an `option` transition result, plus a
  test-only `Post_commit_effect_observer` for staging and lifecycle
  assertions.
- `Driver.latest_committed_output` pull observation, exclusive driver
  attachment, and the `Driver_attached` advance fence.
- Corrected one-shot `Request.Driver_event.handle` and `dispatch` with
  explicit claim results.
- Root-wide bounded FIFO ingress retained as the only admission policy, with
  accounting extended to reset triggers, Poll refreshes, and Poll completions.
- `Eta_test.Test_clock.advance_to` and one test-clock movement claim. Test
  handle time movement delegates to that claim.
- New failure variants, the `Endpoint_action` rename, and portable codec and
  fixture updates.
- Canonical design documents, the semantic-law registry, and `CONTEXT.md`
  updated in the same change. No compatibility shim, overload, or default
  clock.

## Requirements

In this section, "the system" is the Eta Crux capability surface: the
`eta_crux` and `eta_crux_test` packages and the named Eta substrate seams they
use.

### Graph time: API and arithmetic

- The system shall provide an `Eta_crux.Time` computation module whose `now`, `deadline`, `after`, and `interval` constructors return graph descriptions, not Eta effects. ^gtc-8dib
- The system shall keep `Time.monotonic_time` opaque with clock provenance and shall provide `Time.to_ms` for display, metrics, and boundary data. ^gtc-lmpw
- When `Time.add` receives a non-positive duration, the system shall return `` `Past_deadline ``. ^gtc-oi4p
- When a `Time.add` timestamp sum exceeds the representable range, the system shall return `` `Deadline_overflow ``. ^gtc-qakh
- When an application constructs a `now`, `after`, or `interval` description with a non-positive duration, the system shall raise `Invalid_argument` during construction. ^gtc-apbp

### Graph time: clock ownership

- The system shall provide `Eta.Spi.Expert.Clock` with `current`, `same`, `now_ms`, and `sleep`, where `current` captures the exact base clock or `Effect.with_clock` override active in the calling context. ^gtc-xdt8
- When a root performs its initial advancement, the system shall bind the root to the active Eta monotonic clock for the root's lifetime. ^gtc-o4ni
- If a nonterminal advancement runs with an active clock different from the bound clock, then the system shall terminally fail the root with `Runtime_mismatch`. ^gtc-5um9
- After terminal-control selection, the system shall read the clock at most once during each `Root.advance` attempt that has active graph-time nodes. ^gtc-3ip9
- When a nonterminal advancement commits, the system shall give every graph-time node in that advancement the same clock sample. ^gtc-o4qv
- While an advancement attempt is idle, the system shall use the clock sample only to test deadline eligibility. ^gtc-7ucg
- The system shall record the last clock-read sample of each root and shall compare every later root or driver clock read against that sample. ^gtc-9cmj
- If a root or driver clock read returns a sample earlier than the recorded sample, then the system shall latch a root failure with origin `Graph_clock` and trigger `Clock_sample`. ^gtc-610f
- When an idle deadline-eligibility read succeeds, the system shall update the regression baseline without changing any graph-time value. ^gtc-ep7p

### Graph time: deadline and wake

- The system shall track the earliest deadline of the active and necessary graph-time nodes as a private value shared only between the root and its driver. ^gtc-trme
- When `Driver.poll` runs while a graph deadline is already due, the system shall process that deadline as one internal `Clock_due` control event. ^gtc-ws0o
- When `Driver.await` runs with a future graph deadline, the system shall race the ordinary root wake against an Eta sleep to the earliest deadline, cancel the losing wait, and poll again. ^gtc-t43r
- When an ingress wake occurs, the system shall recompute the earliest deadline before the next driver wait. ^gtc-w6yj
- While a root runs after initial start, the system shall select events in the order crash or stop, then `Clock_due`, then the next FIFO ingress item. ^gtc-bi1g
- When several deadlines are due at one shared clock sample, the system shall coalesce them into one `Clock_due` advancement that consumes no ingress item and preserves every queued ingress item. ^gtc-gpx8
- When a one-shot timer commit succeeds, the system shall retire its deadline. ^gtc-eib6
- When a periodic timer commit succeeds, the system shall replace its due deadline with the next future activation-aligned deadline. ^gtc-laxo
- When a `Clock_due` advancement commits, the system shall return the ordinary `Committed` outcome with the complete root output and one mandatory post-commit token, and shall report the result through the ordinary `Deliver` driver event. ^gtc-5heu
- If a `Clock_due` commit changes a `Poll` input, then the system shall stage one Poll run from the latest committed input under the normal post-commit delivery fence. ^gtc-kuwm

### Graph time: timer behavior

- While a timer computation is inactive or unnecessary, the system shall register no deadline for it. ^gtc-v8ym
- When a commit disposes a timer computation, the system shall remove its deadline before the next driver wait. ^gtc-a8mx
- The system shall return the actual shared clock sample from `now ~every` during every advancement. ^gtc-75bf
- While a `now ~every` node is necessary, the system shall schedule activation-aligned clock wakes whose cadence an unrelated Action does not reset. ^gtc-hezs
- While a `deadline` node is active, the system shall present its value as false until its timestamp passes and as true once the timestamp has passed. ^gtc-hw7q
- When an `after` node activates successfully, the system shall measure its duration from that activation advancement. ^gtc-k3ft
- If the activation of a timer node fails, then the system shall install no deadline for that node. ^gtc-ed08
- When the clock moves, the system shall advance an `interval` node arithmetically by the full number of elapsed intervals from its initial value of zero. ^gtc-fbmn
- When an `interval` catch-up exceeds the representable range, the system shall saturate the value at `max_int` and replay no missed ticks. ^gtc-70nf

### Graph time: failure behavior

- If clock regression, internal deadline-arithmetic overflow, a dynamic deadline that is not in the future at activation, or a clock mismatch occurs, then the system shall latch a structured root failure. ^gtc-eb47
- When a graph-time failure is recorded, the system shall attribute a clock mismatch or regression with origin `Graph_clock` and trigger `Clock_sample`, shall preserve the active event trigger for other timer faults, and shall attribute due-time faults with trigger `Clock_due`. ^gtc-a8z6
- If a graph-time dynamic error occurs, then the system shall fail the root without clamping time, ignoring a timer, changing clocks, or substituting wall time. ^gtc-2huo

### Graph time: deterministic test-time control

- The system shall require an explicit `clock:Eta_test.Test_clock.t` argument on `Eta_crux_test.Handle.create` and `Eta_crux_test.Handle.use`. ^gtc-bnro
- The system shall provide `Handle.advance_time_by` and `Handle.advance_time_to`, which raise `Invalid_argument` for a negative duration or a target before the current test time and treat zero movement as a no-op. ^gtc-ldhe
- When a test moves time through handle operations, the system shall move only the supplied test clock and shall run no `frame`, `drain`, `poll`, or `await` operation and trigger no Poll run. ^gtc-vg5h
- The system shall make the supplied test clock the active clock at the root's first advancement by storing one clock capability per handle and running every handle operation that enters the production driver under `Effect.with_clock`. ^gtc-9a8f
- The system shall keep the earliest graph deadline unavailable on the test handle, with no `advance_to_next_deadline` operation. ^gtc-iyvf

### Test-clock movement

- The system shall provide `Eta_test.Test_clock.advance_to : t -> int -> unit`, which raises `Invalid_argument` for a target before the current time and compares and moves time under one movement claim. ^tcl-fcar
- The system shall serialize `adjust`, `set_time`, `advance_to`, and test-handle movement operations on one test clock under one movement claim, which stays held while the clock wakes its due sleepers. ^tcl-12dq
- If movement operations overlap on one test clock, then the system shall give exactly one movement the claim, and each losing movement shall raise `Invalid_argument` before it reads or changes time and shall wake no sleeper. ^tcl-rnv4
- When a test clock moves, the system shall change the time of every root that uses that clock and shall advance no root. ^tcl-eevg
- When a test-handle movement operation runs, the system shall delegate once to the supplied clock's movement claim, perform any target comparison inside that claim, and advance no root. ^tcl-u0dd

### Post-commit effect observation

- The system shall type the results of state-machine transitions and reset callbacks as `'model * (unit, never) Eta.Effect.t option`, where `None` stages no effect and `Some effect` stages one opaque effect. ^pco-oaz8
- The system shall limit post-commit effect observation to application transition effects, structural-reset effects, and Poll-run effects. ^pco-ryjt
- The system shall expose the observer attachment through `Eta_crux.Testing` as an opaque SPI with shared observation types and no custom callbacks. ^pco-4g4s
- The system shall accept one optional `?post_commit_effect_observer` argument on `Eta_crux.Root.create`. ^pco-b9dv
- The system shall provide an `Eta_crux_test.Post_commit_effect_observer` controller with `create`, `attachment`, `poll`, `drain`, and `expect_empty` operations. ^pco-bhjt
- While a controller is attached to a root, the system shall reject a second attachment with `Invalid_argument` and shall provide no detach, reset, or re-attachment operation. ^pco-9j7p
- The system shall number commit indices from zero, consume one index for each successful commit, and consume no index for an idle, rejected, stopped, or failed advancement. ^pco-rkuf
- When a commit succeeds, the system shall record exactly one `Staged` event whose `effects` list is the exact observed effect inventory: zero or one transition effect, zero or more reset effects, and one effect for each Poll run the commit starts. ^pco-iyga
- The system shall introduce one new opaque, root-local effect identity for each `effects` list item, and the list order shall carry no structural, callback, start, or settlement meaning. ^pco-4zp9
- The system shall number event positions from zero, consume one position per recorded event, and define the FIFO observation order by position. ^pco-jtck
- The system shall record `Started` for an effect when Eta Crux has registered the owned job and released the effect to Eta. ^pco-mfbx
- When an observed effect and all its finalizers finish, the system shall record one `Settled` event classified as `Succeeded` for an `Ok` exit, `Interrupted` for an interruption-only cause, and `Failed` for every other cause. ^pco-vz5b
- When a committed effect never enters the Eta runtime, the system shall record `Discarded_before_start` without a reason, covering owner disposal and terminal replacement of a pending batch. ^pco-j13u
- The system shall give each observed effect exactly one lifecycle path — `Staged` then `Started` then `Settled`, or `Staged` then `Discarded_before_start` — with `Staged` before `Started` or `Discarded_before_start`, `Started` before `Settled`, and no settlement order between different effects. ^pco-6awr
- The system shall record observer events into one unbounded FIFO queue with no backpressure and no user callback. ^pco-702c
- When a test calls `poll` or `drain`, the system shall remove and return the next event or the current ordered snapshot, and events from live effects may arrive after either operation returns. ^pco-yben
- The `expect_empty` operation shall check only for undrained events, independent of effect settlement. ^pco-lc7w
- The system shall limit observer event content to positions, commit indices, effect identities, and settlement classes. ^pco-hxm6
- The system shall keep the observer local to one root and one test and shall pass no observer event across a local or serialized adapter boundary. ^pco-d7v2
- The system shall produce identical production results with and without an attached observer, across root output, failure, terminal result, admission result, and fiber settlement. ^pco-0m14
- While no observer is attached, the system shall perform only an attachment check at each event point and shall allocate no observation value or queue entry for a successful commit. ^pco-yq4f
- The system shall guard `poll`, `drain`, and `expect_empty` on one controller with one consumer-operation claim held until the result or assertion error is complete. ^pco-m6gy
- If consumer operations on one controller overlap, then the system shall give exactly one call the claim, and each losing call shall raise `Invalid_argument` before it inspects or removes an event. ^pco-n9h7

### Driver attachment and pull observation

- The system shall give one unstarted root exactly one driver attachment, which holds sole authority to advance that root. ^drv-2kde
- If `Driver.create`, `Handle.create`, or `Handle.use` receives a started or attached root, or `Driver.create` receives a reused binding, then the system shall raise `Invalid_argument`. ^drv-vnzs
- The system shall perform driver attachment as one atomic claim over the root and the binding, and a rejected claim shall leave each otherwise-unused argument available for a later attachment. ^drv-88a3
- If attachment calls overlap on the same root or on the same unused binding, then the system shall let exactly one call succeed, each losing call shall raise `Invalid_argument`, and a losing `Handle.use` call shall not enter its body. ^drv-ezg1
- When `Root.advance` is called directly on a driver-owned root, the system shall return `Error Driver_attached` without consuming an ingress item, reading the clock, or recording an observer event. ^drv-7534
- The system shall provide `Driver.latest_committed_output` as a synchronous query that returns an `'output option`, no commit identity, no delivery state, and no terminal state, and that neither fails nor waits. ^drv-mr88
- The system shall return `None` from `latest_committed_output` before the first commit and `Some` of each commit's complete output after that commit, including an output equal to the prior output. ^drv-uz8j
- The system shall keep the latest committed output available and unchanged while its delivery is pending, after successful delivery, and after delivery failure. ^drv-1ae6
- The system shall retain the latest committed output after normal stop or crash while the driver value remains reachable. ^drv-nh43
- If a `latest_committed_output` query overlaps commit publication, then the system shall return either the previous or the new complete output and no staged or partial value. ^drv-xuol
- A `latest_committed_output` query shall leave delivery tokens, post-commit admission, push delivery, and the latest delivered output untouched. ^drv-q32x
- The test handle shall expose the latest committed output through the production driver query and the latest delivered output at the successful-delivery boundary, and test injection shall use the latest delivered output. ^drv-mp5h
- When one advancement succeeds, the system shall publish observations in this order: the root atomically publishes the complete committed frame, an attached observer records `Staged`, `Root.advance` returns `Committed`, the driver publishes the latest committed output, the driver exposes the matching `Deliver` event, delivery acceptance admits the post-commit batch, and eligible effects record `Started`. ^drv-e5gt

### One-shot handler claims

- The system shall type `Request.Driver_event.dispatch` results as `Dispatched`, `Already_handled`, or `Closed of closure_reason`, and `handle` results as `Handled`, `Different_operation`, `Already_handled`, or `Closed of closure_reason`. ^dsp-fxzm
- The system shall give one request driver event one atomic handler claim, separate from dispatch acknowledgment and response resolution. ^dsp-pfj0
- When `handle` finds an operation-descriptor mismatch, the system shall return `Different_operation` without running a handler or claiming the event. ^dsp-ugx2
- The system shall claim the event for the first matching `handle` or total `dispatch` before that handler runs. ^dsp-xu36
- When a matching `handle` or `dispatch` arrives after a prior claim, the system shall return `Already_handled` without running a handler. ^dsp-o8gq
- If a claimed handler fails with a typed error, then the system shall retain its claim and admit no fall-through to another handler. ^dsp-rs4f
- If cancellation closes a request driver event before the handler claim, then a matching `handle` or `dispatch` shall return `Closed` with the closure reason and start no host work. ^dsp-uwt9
- If the handler claim wins before cancellation, then the system shall deliver the exact closure reason through the installed `on_cancel` callback. ^dsp-e9ri
- When every selective matcher returns `Different_operation` for one request driver event, the system shall convert the unmatched event to the existing `Dispatch_failed` result and request-dispatch failure record. ^dsp-6ehp

### Ingress admission

- The system shall admit all ingress items through one root-wide bounded FIFO queue with one positive, explicit ingress capacity, where each buffered item uses one slot regardless of payload size, endpoint identity, or transport. ^ing-siq4
- The system shall charge each reset trigger, each Poll refresh, and each Poll completion one ingress slot, with no reservation, priority, or separate queue. ^ing-z6vw
- The system shall report every ingress admission outcome as acceptance, `Full`, or `Ingress_closed`, with no drop, slide, replacement, or priority result. ^ing-83wu
- The system shall keep the `Root.create` ingress and request capacities positive, explicit, and independent, with no default value, admission-policy value, endpoint capacity, or reservation argument. ^ing-8y37
- Where an exported endpoint is invoked through a serialized transport, the system shall apply the same root ingress admission contract as a local invocation after boundary validation, preserving acceptance, capacity-full, closure, FIFO position, and close behavior. ^ing-fst5

### Structural model reset

- When a `Reset.scope input ~f` description is compiled, the system shall compile `input` outside the reset scope and shall present the `input` argument of `f` as a read-only computation proxy inside the new scope. ^rst-rly9
- The system shall pass the reset authority of a scope to the `reset` argument of `f` for computations inside the scope. ^rst-nc0b
- The system shall accept an optional `?reset` callback on `State_machine.create` whose default returns the default model with no staged effect and whose custom form may preserve or compute a model and stage one opaque typed-infallible effect. ^rst-y2eh
- The system shall create one fresh structural scope for each `Reset.scope` and shall keep it stable while its enclosing structural occurrence remains active, independent of input and model changes. ^rst-5d9i
- The system shall keep one `Reset.t` authority stable for one active interval, make it stale at scope disposal, and create a fresh authority for a later scope incarnation. ^rst-eibt
- The system shall let an outer reset reach active state machines inside nested reset scopes and shall give an inner reset no reach into its parent scope. ^rst-2rb8
- The system shall keep `Reset.t` a local authority with no codec, remote handle, export node, or driver administration operation. ^rst-hzdm
- When `Reset.trigger` runs, the system shall wait for ordinary root-wide FIFO ingress admission and shall return `Ingress_closed` when closure wins the admission race. ^rst-e7oy
- When a reset trigger is admitted, the system shall append exactly one reset item without running the reset or promising later processing, and repeated triggers shall append separate items that never coalesce. ^rst-vm9q
- If a reset item's scope is disposed before its advancement, then the system shall consume the item and return `Rejected Stale_reset` without a transition. ^rst-kefj
- When a reset of an active scope is accepted, the system shall commit one complete root output, including when every model stays equal and when the scope contains no state machine. ^rst-4rxh
- The reset traversal set shall contain every active state-machine descendant from the committed frame before the reset — in static composition, in the current `bind` branch, for every current `Assoc` key, and inside active nested reset scopes — and no disposed or absent child. ^rst-onh3
- The system shall give every reset callback its own endpoint, input, and model from the same pre-reset committed frame, isolated from every other callback's reset model. ^rst-1045
- The system shall define no reset-callback traversal order, and `Assoc` key order and structural composition order shall carry no reset meaning. ^rst-mkos
- When a reset commits, the system shall stage all reset models and graph changes in one advancement so that no root output observes a partial reset. ^rst-ymrr
- The system shall reconcile reset models through the normal reconciliation, and unchanged children shall preserve their scopes, endpoints, sources, and active intervals. ^rst-djex
- When a changed reset model selects another `bind` branch or changes an `Assoc` input, the system shall dispose removed children through the normal lifecycle and start new children with their default models without delivering the reset to them. ^rst-qbhv
- While an `Assoc` key stays continuously present across a reset, the system shall preserve its keyed incarnation and deliver reset callbacks to its active state-machine descendants. ^rst-lytj
- The system shall keep lifecycle programs unchanged by a reset unrestarted and shall preserve the producer incarnations of unchanged source specifications. ^rst-7mzq
- If a reset callback raises, then the system shall roll back the complete advancement — committing no reset model or graph change and starting no reset effect — and shall record a transition crash whose failure record contains the failing cell and its model diagnostic and no endpoint, Action, or reset identity. ^rst-3ayr
- The system shall own each staged reset effect in the structural scope of its state-machine cell, register all reset effects behind closed gates before removal cancellation, and start eligible sibling reset effects concurrently after removal cancellation and source opening with no published start or settlement order. ^rst-6rcx
- If a reset commit disposes the owning cell of a staged reset effect, then the system shall discard that effect before start, and a later effect defect shall leave the committed reset intact. ^rst-t7ic
- While a root contains no reset scope, the system shall perform no reset traversal and allocate no reset authority, item, or observation record during ordinary advancement. ^rst-3edb

### Poll run result coordination

- The system shall provide `Poll.effect_on_change` — with `input_cutoff`, optional `result_cutoff`, `starting`, `input`, and `effect` arguments — and `Poll.manual_refresh`, which returns a result computation and a computed refresh effect. ^poll-b3e0
- The system shall publish `None` from `Poll.Starting.empty` before the first accepted result and `Some result` for each accepted result. ^poll-u0yw
- The system shall publish the `Starting.initial` value before the first accepted result and shall give later accepted results the same result type. ^poll-sy8h
- The system shall default `result_cutoff` to `Cutoff.phys_equal` and shall use it to control result propagation, not run order. ^poll-1xxp
- When a Poll incarnation activates, the system shall start one run with the latest input and provider from that successful commit. ^poll-tki5
- After activation, the system shall compare each candidate input with the prior committed active input through `input_cutoff` and shall start a run only for a candidate the cutoff accepts. ^poll-e841
- The system shall start at most one automatic run for one Poll node in one advancement, and multiple input changes during stabilization shall coalesce into the latest committed input. ^poll-3cl9
- A provider change alone shall start no run; when a triggering commit occurs, the system shall capture the latest provider and invoke it only at run start. ^poll-ed0r
- If a stabilization fails, then the system shall commit no Poll state and start no Poll effect. ^poll-36nx
- While a Poll node is inactive, the system shall keep no input or provider history for it, and on reactivation the system shall start one run with the latest activation-frame values. ^poll-m5lf
- A test-time movement without a driver advancement shall trigger no Poll run. ^poll-2j0r
- When a refresh effect is invoked, the system shall start one separate Poll run through ordinary blocking FIFO ingress with one ingress slot per accepted invocation, shall return `Ingress_closed` when root closure wins admission, and shall never coalesce invocations. ^poll-5nhm
- If a retained refresh belongs to a disposed Poll incarnation, then the system shall consume it at advancement and return `Rejected Stale_endpoint`. ^poll-drcw
- When a refresh advancement succeeds, the system shall capture the current provider, assign the next run order, and stage one Poll effect, sharing one run order between automatic and manual runs. ^poll-fxv8
- The system shall give each active Poll incarnation one hidden monotonic run order and shall expose no run identity or sequence token in application or test APIs. ^poll-uyga
- If the run order of an incarnation is exhausted, then the system shall raise `Invalid_argument "Eta_crux: poll run order overflow"`, record the failure with origin `Transition` and the current advancement trigger, roll back the complete advancement, and start no Poll effect. ^poll-jd9s
- The system shall run Poll bodies concurrently within one incarnation, with no cancellation, interruption, or waiting of an earlier run by a later run. ^poll-iv1r
- When a Poll body returns, the system shall submit one hidden completion ingress item through ordinary blocking FIFO ingress with one slot and no priority or reservation. ^poll-4ian
- The system shall consider a run complete for result selection when its completion ingress item commits; an effect return alone makes no result current. ^poll-qp48
- The system shall keep the greatest committed run order and its result in the Poll state and shall change the result only for a completion whose run order exceeds the stored order. ^poll-b6b9
- When a stale completion commits, the system shall perform one successful advancement that commits an unchanged root output. ^poll-seh9
- When a newer completion carries an equal result, the system shall advance the stored run order even when `result_cutoff` suppresses propagation. ^poll-59po
- For a stale completion, the system shall skip the `result_cutoff` call, and the system shall compare run orders independent of completion FIFO order. ^poll-nb95
- If root closure wins completion admission, then the system shall discard the result during normal shutdown. ^poll-ertk
- When a Poll trigger commits, the system shall publish the complete root output before the Poll body starts. ^poll-a64q
- The system shall release application transition, structural-reset, and Poll effects as one concurrent class after the lifecycle phase, shall publish no start or settlement order within that class, and shall admit the complete post-commit batch before the next advancement starts. ^poll-jer9
- When a Poll node is disposed, the system shall close the incarnation before it requests cancellation of all active Poll bodies, and cancellation shall not wait for body or finalizer settlement. ^poll-ec08
- If completion and disposal race, then the system shall admit both legal winners: a completion ingress item ahead in FIFO may commit its result first, and a disposal winner fences every queued or later completion into the normal `Stale_endpoint` rejection. ^poll-lbow
- When a Poll node re-enters — including removal and re-entry of the same `Assoc` key — the system shall create a fresh incarnation with its starting output, fresh endpoint identity, fresh run order, and empty input and provider history. ^poll-5bgb
- The system shall fence every completion of an old incarnation from a new incarnation. ^poll-cdus
- The system shall type every Poll body as a typed-infallible `('result, never) Eta.Effect.t`. ^poll-pd9d
- If a Poll provider raises at body start or a Poll body defects during execution, then the system shall latch a root failure with origin `Owned_work` and trigger `Poll_effect`. ^poll-bctg
- When Poll disposal settles with an interruption-only cause, the system shall treat it as normal cleanup and record no failure. ^poll-uaev
- If an input-cutoff or result-cutoff function raises during advancement, then the system shall apply the transition failure protocol, commit no partial Poll state, and start no effect from that failed commit. ^poll-6psq
- While a graph contains no Poll node, the system shall allocate no Poll state, run order, endpoint, hook, observer identity, or observer event during advancement. ^poll-ef4p

### Failure and wire surface

- The system shall extend `Failure.origin` with `Graph_clock`, `Failure.trigger_kind` with `Clock_sample`, `Clock_due`, `Structural_reset`, and `Poll_effect`, `Root.delivery_error` with `Stale_reset`, and `Root.advance_error` with `Driver_attached`. ^fwire-h69w
- The system shall name the endpoint-action trigger kind `Endpoint_action`. ^fwire-q41u
- When the portable failure encoding gains new variants, the system shall update the portable codec, binary tags, wire fixtures, and exhaustive matches in the same change, with no fallback, silent conversion, or untyped error path. ^fwire-m1ly
- The system shall add no wire-frame family for graph time, Reset, Poll, or the post-commit observer. ^fwire-4jpr

### Surface replacement and documentation

- The system shall update the canonical design documents — `README`, `public-api`, `semantic-laws`, `verification`, and `wire-protocol` under `docs/design/eta-crux-v1/` — and the shared domain terms in `CONTEXT.md` in the same change as the interface, codec, fixture, and test changes. ^surf-zgy1
- The system shall keep existing semantic-law IDs stable, revise their text where the accepted surface supersedes the old contract, and register the new `GTC-*`, `RST-*`, `POLL-*`, `PCO-*`, and `TC-*` law families with named executable gates in the same change. ^surf-9rhv
- The system shall provide no compatibility API, transitional overload, default clock, or silent conversion for the replaced contracts. ^surf-se1m

## Implementation Decisions

All decisions come from the resolved capability-audit tickets. The normative
detail lives in those tickets; this section records the decisions that shape
the implementation.

**Modules.** `eta_crux` gains the top-level computation modules `Time`,
`Reset`, and `Poll`, plus `Testing` for the observer attachment SPI and shared
observation types. There is no capability umbrella module. `eta_crux_test`
gains `Post_commit_effect_observer`. `Eta_test.Test_clock` gains `advance_to`.
Eta core gains `Eta.Spi.Expert.Clock` as library SPI, not application API.
`Eta_signal.Time` keeps its generic timer contract; graph time does not use
it.

**Effect absence.** `State_machine.create` transition results and the optional
reset callback use one shape, from the
[Staged-effect observability](../../wayfinder/eta-crux-capability-audit/issues/12-staged-effect-observability.md)
and
[Structural model reset](../../wayfinder/eta-crux-capability-audit/issues/20-structural-model-reset.md)
decisions:

```ocaml
'model * (unit, never) Eta.Effect.t option
```

This replaces the mandatory effect and removes the physical-identity check
against `Eta.Effect.unit`. The option is not a command wrapper.

**Time API.** From
[Graph time and deterministic clock control](../../wayfinder/eta-crux-capability-audit/issues/09-graph-time-and-deterministic-clock-control.md):

```ocaml
module Time : sig
  type monotonic_time
  type arithmetic_error = [ `Deadline_overflow | `Past_deadline ]
  val to_ms : monotonic_time -> int
  val add :
    monotonic_time -> Eta.Duration.t ->
    (monotonic_time, arithmetic_error) result
  val now : every:Eta.Duration.t -> monotonic_time t
  val deadline : monotonic_time -> bool t
  val after : Eta.Duration.t -> bool t
  val interval : Eta.Duration.t -> int t
end
```

**Clock SPI.** `Eta.Spi.Expert.Clock` carries `current`, `same`, `now_ms`,
and `sleep`. The token is an owner-domain value used only inside Eta SPI
effect callbacks. The root binds one clock token for its lifetime.

**Reset API.** `Reset.scope` and `Reset.trigger` per
[Structural model reset](../../wayfinder/eta-crux-capability-audit/issues/20-structural-model-reset.md):

```ocaml
module Reset : sig
  type t
  val scope :
    'input computation ->
    f:(reset:t computation -> input:'input computation -> 'output computation) ->
    'output computation
  val trigger : t -> (unit, Endpoint.admission_error) Eta.Effect.t
end
```

**Poll API.** Per
[Poll run result coordination](../../wayfinder/eta-crux-capability-audit/issues/21-poll-run-result-coordination.md):
`Poll.Starting.empty` and `Starting.initial`, `effect_on_change` with
`input_cutoff` and optional `result_cutoff`, and `manual_refresh` returning a
result computation and a computed refresh effect. Run order is hidden; no run
identity reaches any public type.

**Observer API.** The event types are decision-rich; from
[Staged-effect observability](../../wayfinder/eta-crux-capability-audit/issues/12-staged-effect-observability.md):

```ocaml
type settlement = Succeeded | Interrupted | Failed

type event =
  | Staged of { position : Event_position.t; commit : Commit_index.t;
                effects : Effect_id.t list }
  | Started of { position : Event_position.t; effect : Effect_id.t }
  | Settled of { position : Event_position.t; effect : Effect_id.t;
                 settlement : settlement }
  | Discarded_before_start of { position : Event_position.t;
                                effect : Effect_id.t }
```

`Eta_crux.Testing` exposes only the shared types and one opaque attachment
type. `Root.create` accepts
`?post_commit_effect_observer:Testing.post_commit_effect_observer`. The
`eta_crux_test` controller re-exports the shared types and owns queue access.

**Driver surface.** `Driver` gains
`val latest_committed_output : 'output t -> 'output option`. Attachment is
exclusive and atomic per requirements `drv-2kde` through `drv-ezg1`.
`Root.advance_error` gains `Driver_attached`.

**Dispatch surface.** Per
[Host-operation layers](../../wayfinder/eta-crux-capability-audit/issues/16-host-operation-layers.md),
`dispatch` returns `dispatch_result` and `handle` returns `handle_result`:

```ocaml
type dispatch_result = Dispatched | Already_handled | Closed of closure_reason
type handle_result =
  | Handled | Different_operation | Already_handled | Closed of closure_reason
```

Descriptor identity defines a handler match. `handle` and `dispatch` stay
dispatch primitives, not a layer chain.

**Test surface.** `Handle.create` and `Handle.use` require
`clock:Eta_test.Test_clock.t`. `Handle` gains `advance_time_by`,
`advance_time_to`, `latest_committed_output`, and
`latest_delivered_output`; `last_output` is gone. `Eta_test.Test_clock` gains
`advance_to : t -> int -> unit`. `set_time` keeps its direct test-setup
contract.

**Shared terms.** Action, ingress item, message, Poll run, request, root
output, latest committed output, and latest delivered output take the meanings
fixed by
[Coherent accepted capability surface](../../wayfinder/eta-crux-capability-audit/issues/18-coherent-accepted-capability-surface.md).
Poll terminology uses run, run order, and run history — never request.

**Ownership.** Eta owns effect execution, scheduling, interruption, scopes,
finalizers, clocks, and sleeps. Eta Crux owns graph time, deadlines, driver
wakes, actions, ingress, reset, Poll run order, commit publication, shell
requests, and handler claims. `Driver` owns latest committed-output retention.
Adapters own delivery state, reconciliation, operation routing, buffers,
retries, and provider diagnostics. `Eta_crux.Testing` owns observation types;
`eta_crux_test` owns the observer controller. Applications own models,
builders, Poll inputs, cutoffs, and domain policy.

**Failure surface.** `Failure.origin` gains `Graph_clock`;
`Failure.trigger_kind` gains `Clock_sample`, `Clock_due`, `Structural_reset`,
and `Poll_effect`; `Root.delivery_error` gains `Stale_reset`;
`Root.advance_error` gains `Driver_attached`; `Endpoint_message` becomes
`Endpoint_action`. Portable failure variants get codec tags and fixture
updates in the same change.

**Replacement.** No external Eta Crux consumer exists. The accepted surface
replaces the current contract directly: public interfaces, canonical design
documents, laws, tests, codecs, fixtures, and repository callers change
together. There is no migration sequence or compatibility API.

## Testing Decisions

A good test observes external behavior at a public seam — driver events,
committed output, admission results, observer events, failure records, and
controlled witnesses — and never asserts internal data structures. Every
law-bearing claim in a public interface gets its named executable gate and its
registry row in the same change, per the repository executable-law policy.

**Seams** (confirmed with the user):

1. Production public surface (`Root`, `Driver`, endpoints, exports, requests)
   in `test/crux/laws` and `test/crux/unit`. Carries the GTC, RST, POLL,
   ingress, pull-observation, and dispatch-claim laws. No queue introspection
   or test-only admission controller is added.
2. Test-harness surface (`Handle` with mandatory test clock, `Controlled`,
   `Controlled_source`, `Post_commit_effect_observer`) in `test/crux/unit` and
   `test/crux/laws`. Carries the PCO, handle, and deterministic-time laws.
3. Race harness with private barriers at contract claim points in
   `test/crux/races`. The barriers stop contenders at driver attachment,
   test-clock movement, observer-consumer claims, reset disposal, and Poll
   disposal. They add no public API — the same seam kind the existing race
   gates use.
4. Transport conformance in `test/crux/conformance`: identity and serialized
   bindings produce the same observations after boundary validation.
5. Negative compile fixtures in `test/crux/negative`:
   `poll_effect_rejects_typed_error` beside the existing staged-effect
   fixture.
6. Disabled-path benchmarks under `bench/`: observer, reset, and Poll
   disabled paths must show equal per-action allocation and no more than a 5%
   median regression in two of three comparisons, per the existing
   disabled-telemetry threshold.

**Named gates.** The law registry in
[semantic-laws.md](../../design/eta-crux-v1/semantic-laws.md) gains the
`GTC-*`, `RST-*`, `POLL-*`, `PCO-*`, and `TC-*` families with the gate names
fixed in the capability tickets, including
`race_driver_attachment_both_winners`, `test_driver_attachment_fence`,
`race_test_clock_movement_both_winners`,
`race_handle_shared_clock_movement_both_winners`,
`race_post_commit_effect_observer_read_both_winners`,
`race_reset_vs_disposal_both_winners`,
`race_poll_completion_vs_disposal_both_winners`,
`qcheck_latest_committed_output`, `race_pull_vs_commit_both_winners`,
`test_pull_does_not_complete_delivery`, and
`test_handle_output_boundaries`. Existing `A-*`, `T-*`, `L-*`, `S-*`, `R-*`,
`D-*`, `O-*`, and `H-*` laws keep their IDs; their text is revised where the
accepted surface supersedes them.

**Property discipline.** Each qcheck property states its generated class and
observation boundary, executes every side of its equation, and proves the
discriminating coverage its claim needs — exact effect inventories, both race
winners, all completion permutations, out-of-order settlement. Generated
failures print the graph, commit sources, effect sources, controlled
settlements, and observed events. Tests with no valid background work finish
with an empty fiber census.

**Prior art.** `test/crux/laws/test_eta_crux_laws.ml` for registry-backed
qcheck properties, `test/crux/races/test_eta_crux_races.ml` for barrier races,
`test/crux/conformance/test_eta_crux_conformance.ml` for transport
equivalence, `test/crux/negative` for compile-fail fixtures, and the existing
disabled-telemetry benchmark threshold for allocation gates.

## Out of Scope

- Eta Crux implementation sequencing beyond this spec's contract: the spec
  fixes behavior, not internal data structures or build order.
- Rejected capabilities, with no reopening condition: a separate external
  graph input, distinct startup facts and flags, host-owned streaming
  operations, per-endpoint or reserved or lossy or coalescing ingress
  admission, host-operation layers, replay, time travel, graph inspection, and
  an inspectable command algebra. A later demand starts a new decision effort
  with new consumer evidence.
- Action observation and bounded action history: deferred until a direct
  consumer demonstrates the diagnostic gap, per
  [Action history and diagnostics](../../wayfinder/eta-crux-capability-audit/issues/17-action-history-and-diagnostics.md).
- A generic bounded log-retention sink, which belongs to Eta observability.
- Changes to `Eta_signal.Time`.
- Compatibility APIs, transitional overloads, default clocks, migration
  tooling, and release planning.
- Taumel or Sliml application design; UI components, renderers, browser APIs,
  and package tooling; performance tuning that changes no capability contract.

## Further Notes

Provenance: every decision traces to the
[Eta Crux capability audit map](../../wayfinder/eta-crux-capability-audit/map.md)
and its resolved tickets — tickets 09, 12, 14, 15, 16, 20, and 21 for the
adopted designs, ticket 18 for their reconciliation, and ticket 19 for
coverage closure. Requirement prefixes mirror the law families (`GTC`, `TC`,
`PCO`, `RST`, `POLL`) plus surface families (`drv`, `dsp`, `ing`, `fwire`,
`surf`).

The normative behavior registry for this work is
[semantic-laws.md](../../design/eta-crux-v1/semantic-laws.md). Law-bearing
prose added to `eta_crux.mli`, `eta_crux_test.mli`, or the `eta_test` clock
interface needs its named gate and registry row in the same change.
