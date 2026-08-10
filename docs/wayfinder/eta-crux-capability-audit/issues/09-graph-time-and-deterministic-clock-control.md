# Graph time and deterministic clock control

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does Eta Crux need graph time and deterministic test-time control?

Check the claim that the graph has no clock, deadlines cannot wake the driver,
and the test handle cannot advance time. Compare three possible ownership
shapes:

- time as graph input with a driver-visible next deadline.
- time as a shell operation.
- time as an application-owned source or staged effect.

Decide whether to adopt, defer with a precise condition, or reject the
capability. If adopted, specify the API shape, clock ownership, wake protocol,
semantic laws, deterministic test controls, failure behavior, and migration
effects.

## Answer

### Decision

**Adopt graph time and deterministic test-time control.**

The reported claim is correct:

- The public Eta Crux graph has no clock.
- A graph deadline cannot wake the driver.
- The test handle cannot move time.

The current application-owned solution was deliberate. Applications can still
use Eta effects for operation-specific deadlines. That solution does not cover a
time value that changes graph output without an application action.

Eta supplies the monotonic clock, sleep operation, and test clock. Eta Crux owns
graph sampling, active deadlines, driver wake eligibility, and the test-handle
contract.

Bonsai supports graph time through one driver-owned time source. Its host moves
time and requests another frame. Bonsai does not expose a next deadline or a
blocking driver wake.

Eta Crux has a blocking `Driver.await` operation. Therefore, Eta Crux also needs
a private earliest-deadline protocol. A shell operation alone does not provide
reactive graph time. Application sources and staged effects require each
application to rebuild this protocol.

The supporting evidence is in the
[current baseline](../../../../.scratch/research/eta-crux-capability-audit/01-current-eta-crux-capability-baseline.md),
[decision history](../../../../.scratch/research/eta-crux-capability-audit/02-prior-decision-and-requirement-provenance.md),
[Bonsai census](../../../../.scratch/research/eta-crux-capability-audit/bonsai-public-capability-census.md),
[Eta substrate audit](../../../../.scratch/research/eta-crux-capability-audit/06-eta-substrate-capability-support.md),
and
[consumer audit](../../../../.scratch/research/eta-crux-capability-audit/07-representative-consumer-friction.md).

### Public API shape

Add this graph surface to `eta_crux`:

```ocaml
module Time : sig
  type monotonic_time
  type arithmetic_error = [ `Deadline_overflow | `Past_deadline ]

  val to_ms : monotonic_time -> int

  val add :
    monotonic_time ->
    Eta.Duration.t ->
    (monotonic_time, arithmetic_error) result

  val now : every:Eta.Duration.t -> monotonic_time t
  val deadline : monotonic_time -> bool t
  val after : Eta.Duration.t -> bool t
  val interval : Eta.Duration.t -> int t
end
```

The operation names and value roles follow `Eta_signal.Time`. Eta Crux
constructors return descriptions, not Eta effects. Dynamic errors terminally
fail the root instead of using the Eta Signal construction-error channel.

`monotonic_time` is opaque and carries clock provenance. `to_ms` supports
display, metrics, and boundary data. A wall-clock integer is not a valid graph
timestamp.

`add` returns `Past_deadline` for a non-positive duration. It returns
`Deadline_overflow` when the timestamp sum cannot be represented.

`now`, `after`, and `interval` require positive durations. An invalid static
duration raises `Invalid_argument` when the application builds the description.

Eta effects continue to own `sleep`, `delay`, `timeout`, and effect schedules.
Eta Crux does not add the corresponding Bonsai effect helpers.

### Clock ownership

The current Eta SPI does not expose a stable active-clock value. Add this module
to `Eta.Spi.Expert`:

```ocaml
module Clock : sig
  type t

  val current : context -> t
  val same : t -> t -> bool
  val now_ms : t -> int
  val sleep : t -> Eta.Duration.t -> unit
end
```

This module is Eta library SPI, not application API. `current` captures the
exact base clock or `Effect.with_clock` override active in the context. `same`
compares stable clock identity. `now_ms` and `sleep` use the captured clock
instead of a later dynamic override.

The token is an owner-domain value. Eta Crux uses it only inside Eta SPI effect
callbacks.

The root binds to the active Eta monotonic clock during initial advancement. The
binding lasts for the root lifetime.

All graph-time nodes and driver deadline sleeps use that clock. Advancement with
a different active clock terminally fails with `Runtime_mismatch`.

After terminal-control selection, each `Root.advance` attempt with active
graph-time nodes reads the clock at most once. Initial start and each committed
nonterminal advancement take exactly one sample. All graph-time nodes in that
advancement share the sample. An idle attempt can use the sample only to test
deadline eligibility.

The root stores the last clock-read sample. Every later root or driver clock read
must be greater than or equal to that sample. A successful idle eligibility read
updates this regression baseline, but it does not update a graph-time value. A
lower sample latches a `Graph_clock` failure with trigger `Clock_sample`.

### Deadline and wake protocol

The root tracks the earliest deadline from active and necessary graph-time nodes.
The value stays private between the root and driver. The public API adds no
`Root.next_deadline` or `Driver.next_deadline`.

`Driver.poll` treats an already-due deadline as one internal `Clock_due` control
event. `Driver.await` races the ordinary root wake against an Eta sleep to the
earliest deadline. It cancels the losing wait and polls again.

An ingress wake causes the driver to recompute the earliest deadline. This rule
covers a new earlier deadline and removal of the current earliest deadline.

After initial start, event priority is:

1. crash or stop.
2. `Clock_due`.
3. the next FIFO ingress action.

All deadlines due at the shared clock sample coalesce into one `Clock_due`
advancement. The event does not consume an ingress action.

A committed one-shot timer retires its deadline. A committed periodic timer
replaces its due deadline with its next future, activation-aligned deadline.
Thus a past deadline cannot cause repeated `Clock_due` events.

A successful clock advancement returns the ordinary `Root.Committed` outcome.
It contains the complete root output and one mandatory post-commit token.
`Driver.event` remains unchanged. The driver reports the result through its
ordinary `Deliver` event.

### Timer behavior

A timer exists only while its computation is active and necessary. A committed
disposal removes its deadline before the next driver wait. No timer remains
registered for an inactive branch.

`now ~every` returns the actual shared clock sample during every advancement.
`every` schedules activation-aligned clock wakes while the node is necessary. An
unrelated action does not reset that cadence.

`deadline timestamp` is initially false and changes to true once. The timestamp
must be in the future and must belong to the root clock when the node becomes
active.

`after duration` measures from the successful advancement that activates the
node. A failed activation does not install its deadline.

`interval duration` starts at zero. After a clock jump, it advances by the full
number of elapsed intervals. It computes this change arithmetically and
saturates at `max_int`. It does not replay missed ticks.

### Semantic laws

| Law | Contract | Implementation gate |
|---|---|---|
| GTC-01 Initial binding | Initial advancement captures one `Eta.Spi.Expert.Clock.t`. The root uses that token for its complete lifetime. | `qcheck_graph_time_initial_binding` |
| GTC-02 Shared sample | After terminal selection, one `Root.advance` attempt with active graph-time nodes reads the clock at most once. Each committed nonterminal advancement uses exactly one shared sample. | `qcheck_graph_time_shared_sample` |
| GTC-03 Clock provenance | A later nonterminal advancement with a different `Eta.Spi.Expert.Clock.t` terminally fails with `Runtime_mismatch`. | `test_graph_time_runtime_mismatch` |
| GTC-04 Structural ownership | Only active and necessary nodes contribute deadlines. Committed disposal removes their deadlines before the next driver wait. | `qcheck_graph_time_structural_ownership` |
| GTC-05 Deadline wake | `Driver.poll` processes an already-due deadline. A due deadline also makes `Driver.await` continue without ingress. | `qcheck_graph_time_deadline_wake` |
| GTC-06 Await race | `Driver.await` cancels the losing wait. An ingress wake causes a new deadline calculation before the next wait. | `qcheck_graph_time_await_race` |
| GTC-07 Event priority | Crash and stop precede `Clock_due`. `Clock_due` precedes FIFO ingress. | `qcheck_graph_time_event_priority` |
| GTC-08 Due coalescing | One clock sample produces at most one `Clock_due` advancement. The event preserves every queued ingress action. | `qcheck_graph_time_due_coalescing` |
| GTC-09 Timer progress | A committed one-shot timer retires its deadline. A committed periodic timer installs its next future deadline. | `qcheck_graph_time_timer_progress` |
| GTC-10 Current time | Each committed advancement gives `now` the shared clock sample. The activation-aligned `every` cadence does not reset after an action. | `qcheck_graph_time_now_cadence` |
| GTC-11 One-shot deadline | `deadline` changes from false to true once in one active interval. Its timestamp is future and belongs to the root clock at activation. | `qcheck_graph_time_deadline` |
| GTC-12 Relative deadline | `after` measures from successful activation. A failed activation installs no deadline. | `qcheck_graph_time_after_activation` |
| GTC-13 Interval catch-up | `interval` starts at zero. It catches up arithmetically, saturates at `max_int`, and does not replay missed ticks. | `qcheck_graph_time_interval_catch_up` |
| GTC-14 Commit fence | A successful `Clock_due` event produces one complete output and one mandatory post-commit token. | `qcheck_graph_time_commit_fence` |
| GTC-15 Driver bound | One `Driver.poll` or `Driver.await` operation performs at most one advancement. | `qcheck_graph_time_driver_bound` |
| GTC-16 Test separation | Moving test time does not advance Eta Crux. A later `frame` or `drain` observes due work through the production driver. | `test_graph_time_handle_separation` |
| GTC-17 Test monotonicity | Test movement rejects negative deltas and backward targets with `Invalid_argument`. Zero movement is a no-op. | `test_graph_time_handle_validation` |
| GTC-18 Transport independence | Identity and serialized bindings observe the same clock advancements and outputs. | `qcheck_graph_time_transport_equivalence` |
| GTC-19 Dynamic failure | Each root or driver clock read compares against the last successful read. Regression, internal overflow, a past dynamic deadline, or mismatch terminally fails the root. | `test_graph_time_dynamic_failures` |
| GTC-20 Failure attribution | A clock mismatch or regression uses `Graph_clock` and `Clock_sample`. Timer faults preserve the event trigger, and due-time faults use `Clock_due`. | `test_graph_time_failure_attribution` |
| GTC-21 No fallback | Eta Crux does not clamp time, ignore a timer, change clocks, or use wall time as a fallback. | `test_graph_time_no_fallback` |
| GTC-22 Static validation | `now`, `after`, and `interval` reject non-positive durations with `Invalid_argument`. `Time.add` returns its documented arithmetic result. | `test_graph_time_static_validation` |

### Deterministic test controls

Add a mandatory `clock:Eta_test.Test_clock.t` argument to
`Eta_crux_test.Handle.create` and `Eta_crux_test.Handle.use`.

Add these operations:

```ocaml
val advance_time_by :
  ('output, 'incoming) t ->
  Eta.Duration.t ->
  unit

val advance_time_to :
  ('output, 'incoming) t ->
  int ->
  unit
```

`advance_time_by` raises `Invalid_argument` for a negative duration.
`advance_time_to` raises `Invalid_argument` for a target before the current test
time. Zero movement is a no-op.

These operations move only the supplied test clock. They do not run `frame`,
`drain`, `poll`, or `await`. Tests move time and then use the existing driver
operations.

The supplied test clock must be the active clock when the root first advances.
The handle creates one capability from that clock and stores it. Each handle
operation that enters the production driver runs under
`Effect.with_clock capability`. Thus initial advancement captures the supplied
clock, and later handle operations preserve its identity.

The handle does not expose the earliest deadline. It adds no
`advance_to_next_deadline` operation.

### Failure behavior

Static duration errors fail during description construction. `Time.add` returns
its arithmetic errors as values.

These dynamic errors latch a structured root failure:

- clock regression.
- internal deadline arithmetic overflow during activation or timer progress.
- a deadline that is not in the future during activation.
- `Runtime_mismatch`.

Add `Graph_clock` to `Failure.origin`. Add `Clock_sample` and `Clock_due` to
`Failure.trigger_kind`.

A clock mismatch or regression uses `Graph_clock` as its origin and
`Clock_sample` as its trigger. Other timer faults preserve the active event
trigger. A due-time fault uses `Clock_due`. The normal crash notification and
settlement protocol then applies.

Eta Crux does not clamp a timestamp, ignore a timer, change clocks, or use wall
time as a fallback.

### Migration effects

The `Time` module is an additive graph API. `Root.create`, `Root.advance`,
`Driver.event`, `Driver.poll`, and `Driver.await` keep their public signatures.

Eta core gains the private `Eta.Spi.Expert.Clock` seam. The application-facing
Eta effect API does not change.

The new failure variants require updates to exhaustive matches over
`Failure.origin` and `Failure.trigger_kind`.

The mandatory test-clock argument changes all `Handle.create` and `Handle.use`
calls. Most existing Crux tests already receive an `Eta_test.Test_clock.t`. They
must pass that value to the handle.

Tests that use the private default clock of `Eta_test.Run.run` must create a
clock explicitly. They must pass it to both `Run.run ~clock` and the handle.

The new failure variants change portable failure encoding. Implementation must
update the portable codec, binary tags, wire fixtures, and exhaustive matches.

Implementation must add the graph-time laws, deterministic handle tests, failure
tests, driver race tests, and transport-equivalence tests. The implementation
change must also update canonical design documents and the executable-law
registry. No compatibility overload or default clock is permitted.
