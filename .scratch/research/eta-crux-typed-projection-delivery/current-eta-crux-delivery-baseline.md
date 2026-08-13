# Current Eta Crux delivery baseline

Ticket: [`docs/wayfinder/eta-crux-typed-projection-delivery/issues/01-current-eta-crux-delivery-baseline.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/issues/01-current-eta-crux-delivery-baseline.md)

## Question

What do current Eta Crux code, laws, tests, and prior decisions require for these five concerns:

- commit publication
- delivery
- acknowledgment
- pull observation
- serialized session replacement

This report records current facts, prior decisions, stale claims, and gaps.
It does not select a public interface for typed projection delivery.

## Method

Primary sources only.

| Source | Role |
|---|---|
| `lib/crux/eta_crux.mli` | Public production surface |
| `lib/crux/crux_root.ml`, `crux_driver.ml`, `crux_driver_base.ml`, `crux_driver_serialized.ml`, `crux_wire.ml`, `crux_host.ml` | Commit, delivery, acknowledgment, pull, and session paths |
| `lib/crux_test/eta_crux_test.mli`, `crux_test_handle.ml` | Public test surface and output boundaries |
| `docs/design/eta-crux-v1/{README,public-api,semantic-laws,verification,wire-protocol}.md` | Design authority, laws, gates, and wire frames |
| `test/crux/{unit,laws,races,conformance}` | Named executable gates |
| `lib/crux/bench/bench_eta_crux.ml` | Named performance rows |
| `docs/wayfinder/eta-crux-capability-audit/` | Adopted delivery and pull decisions |
| `.scratch/research/eta-crux-capability-audit/` | Prior baseline and provenance |
| `docs/wayfinder/eta-crux-first-principles/` | Earlier ownership and host-adapter decisions |

Classification:

| Class | Meaning |
|---|---|
| Current fact | Present code, law, named gate, or design document |
| Prior decision | Resolved ticket that still binds the current contract |
| Stale claim | Earlier report or ticket that no longer matches current sources |
| Gap | A required law, ticket coverage rule, or named gate that current sources do not meet |

This report did not run the test suite or the benchmark gate.
Named gates are present in source. Pass or fail status is not re-executed.

## Current facts

### Ownership seams

Eta Crux owns computation structure, identity, advancement, graph time, actions,
ingress, reset, Poll run order, and commit publication
([`docs/design/eta-crux-v1/README.md`](../../../docs/design/eta-crux-v1/README.md)
lines 34-38).
Eta Crux also owns typed output, shell requests, and handler claims (same span).
The driver retains the latest committed output for pull observation (same span).
Eta owns effects, scopes, cancellation, resources, supervision, causes, clocks, and sleeps (same span).

The four layers are computation, root advancement, driver delivery, and host-adapter reconciliation ([`README.md`](../../../docs/design/eta-crux-v1/README.md) lines 41-49).
One unstarted root accepts one exclusive driver attachment (lines 51-54).
The application cannot observe whether the shell uses identity delivery or serialized delivery (same span).
The serialized binding adds wire validation and session administration before the shared typed boundary (same span).

The accepted capability surface assigns these owners ([`docs/wayfinder/eta-crux-capability-audit/issues/18-coherent-accepted-capability-surface.md`](../../../docs/wayfinder/eta-crux-capability-audit/issues/18-coherent-accepted-capability-surface.md) lines 102-115):

| Concern | Owner |
|---|---|
| Actions, ingress, structural reset, Poll run order, and commit publication | Eta Crux |
| Latest committed-output retention | `Driver` |
| Successful-delivery state and host reconciliation | Adapters |
| Models, builders, Poll inputs, cutoffs, result values, and domain policy | Applications |
| Host registration, operation routing, buffers, retries, and provider diagnostics | Adapters and providers |

The typed-projection map repeats the same seam.
Eta Crux owns stabilization, atomic commit, delivery order, serialized sessions, and delivery acknowledgment ([`docs/wayfinder/eta-crux-typed-projection-delivery/map.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/map.md) lines 16-17).
The driver remains the only transport writer (same span).

Identity and serialized bindings share one driver type ([`lib/crux/eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 681-741).
`Driver.Binding.identity` carries typed values ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 687-689).
`Driver.Binding.serialized` returns a candidate admin handle ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 691-695).
`Serialized_session.replace` uses that admin handle ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 616-619).
`Hosted.Control` exposes only `request_stop` ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 770-774).
Session replacement is absent from `Hosted.Control` ([`docs/design/eta-crux-v1/public-api.md`](../../../docs/design/eta-crux-v1/public-api.md) lines 718-720).

The identity binding owns direct typed delivery only ([`docs/wayfinder/eta-crux-first-principles/issues/18-transport-equivalence.md`](../../../docs/wayfinder/eta-crux-first-principles/issues/18-transport-equivalence.md) lines 90-91).
The serialized binding owns the active session, handle registry, codecs, frames, sequences, protocol closure, and session replacement (lines 93-99).

### Commit publication

One advancement selects at most one event (law `T-01`, [`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 53).
An empty root returns `Idle` with no stabilization and no output delivery (`T-02`, line 54).
Start and each accepted application action commit one complete root output, including an output equal to the prior output (`T-03`, line 55).
Model, graph, scopes, lifecycle manifests, output, and effect eligibility commit in one root-frame publication (`T-04`, line 56).
A pre-publication failure preserves the previous frame (`T-04`, line 56).
A later defect cannot roll back and crashes the root before output delivery (`T-04`, line 56).
A commit returns one mandatory post-commit token (`T-05`, line 57).
No later advancement starts before that token starts (`T-05`, line 57).

`Root.advance` is a typed-infallible effect ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 672-677).
The comment states that the effect is synchronous work on the caller fiber and never blocks (lines 675-677).
The public outcomes are `Idle`, `Rejected`, `Committed`, `Stopped`, and `Failed` (lines 650-663).
`Committed` carries the complete output and the post-commit token (lines 653-656).
Advance errors are `Already_advancing`, `Awaiting_post_commit`, `Closed`, and `Driver_attached` (lines 644-648).

The root install path writes `root.committed_frame` and then returns `Committed` ([`lib/crux/crux_root.ml`](../../../lib/crux/crux_root.ml) lines 808-818 and 831-846).
The same path records the optional observer `Staged` inventory through `record_staged_effects` (lines 737-748 and 810).
It then sets the phase to `Awaiting_post_commit` (lines 811 and 839).

A cutoff never suppresses committed root-output delivery (`C-05`, [`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 20).
V1 exposes no typed observation plan ([`docs/wayfinder/eta-crux-first-principles/issues/09-typed-observation-plan.md`](../../../docs/wayfinder/eta-crux-first-principles/issues/09-typed-observation-plan.md) lines 35-47).
One committed root output is the only application observation boundary (same span).

### Delivery

The accepted observable order after one successful advancement is ([`issues/18-coherent-accepted-capability-surface.md`](../../../docs/wayfinder/eta-crux-capability-audit/issues/18-coherent-accepted-capability-surface.md) lines 260-270):

1. The root publishes the complete committed frame.
2. An attached observer records `Staged`.
3. `Root.advance` returns `Committed`.
4. The driver publishes `latest_committed_output`.
5. The driver exposes the matching `Deliver` event.
6. Delivery acceptance admits the post-commit batch.
7. Eligible effects record `Started`.

Law `O-02` states that the driver delivers output after commit and before post-commit work ([`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 216).
Adapter callbacks never run during stabilization (`O-02`, same line).
Law `D-02` states that output delivery completes before post-commit admission (line 187).
A delivery token accepts one answer (`D-02`, same line).
Law `POLL-12` states that output delivery precedes Poll start (line 121).

`Driver.Delivery` carries the complete output and a reason ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 707-725).
The reasons are `Advancement` and `Session_replacement` (lines 708-710).
Identity poll returns `Some (Deliver delivery)` after it stores `last_output` ([`lib/crux/crux_driver.ml`](../../../lib/crux/crux_driver.ml) lines 528-545).
Serialized poll encodes the output and sends `Wire.Frame.Output_deliver` (lines 546-580).
Serialized poll then returns `None` (line 580).
The serialized delivery is transport-owned.

`Adapter.resource` receives `{ output; reason }` ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 746-758).
`Hosted.run` answers that callback and then answers the driver token ([`lib/crux/crux_host.ml`](../../../lib/crux/crux_host.ml) lines 81-103).

### Acknowledgment

The identity acknowledgment is `Driver.Delivery.delivered` or `Driver.Delivery.failed` ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 718-725).
A second answer returns `Already_completed` (lines 713 and 720-725).
`delivered` starts the post-commit token in the same call ([`lib/crux/crux_driver.ml`](../../../lib/crux/crux_driver.ml) lines 157-169).
`failed` latches `Adapter_delivery` with trigger `Output_delivery` and does not start ordinary post-commit work (lines 170-183).

Law `F-05` states that output-delivery failure cannot roll back a commit ([`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 182).
It suppresses ordinary batch work and records `Adapter_delivery` (same line).
Law `D-03` states that stop or crash during pending delivery closes ingress but preserves that committed delivery (line 188).
Terminal work starts after the answer (same line).

The serialized acknowledgment is `Wire.Frame.Output_result` ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 483-487).
The result is `` `Accepted `` or `` `Failed of string `` (lines 442-443).
`handle_serialized_frame` maps a matching `Output_result` onto `Delivery.delivered` or `Delivery.failed` ([`lib/crux/crux_driver_serialized.ml`](../../../lib/crux/crux_driver_serialized.ml) lines 312-363).
A replacement result resolves the replacement promise instead (lines 314-348).
A failed replacement result latches `Adapter_delivery` and returns `Serialized_session.Crashed` (lines 326-340).

Session loss during pending delivery answers the token as a failed delivery ([`crux_driver_serialized.ml`](../../../lib/crux/crux_driver_serialized.ml) lines 111-117).
The named gate is `test_session_loss_settles_pending_delivery` ([`test/crux/conformance/test_eta_crux_conformance.ml`](../../../test/crux/conformance/test_eta_crux_conformance.ml) lines 478-519).
That gate observes `Adapter_delivery` and `Output_delivery` (lines 514-519).

A local decoder diagnostic never enters a remote result (`W-10`, [`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 209).
A failed delivery carries one adapter-owned, bounded, redacted diagnostic string ([`docs/design/eta-crux-v1/wire-protocol.md`](../../../docs/design/eta-crux-v1/wire-protocol.md) line 266).

### Pull observation

`Driver.latest_committed_output` is a synchronous query ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) line 739).
It returns `'output option` (same line).
The public-api text states that the query retains no commit identity, delivery state, or terminal state ([`public-api.md`](../../../docs/design/eta-crux-v1/public-api.md) lines 670-671).
The implementation reads `driver.last_output` under the driver lock ([`lib/crux/crux_driver.ml`](../../../lib/crux/crux_driver.ml) lines 679-680).

The driver writes `last_output` after `Root.advance` returns `Committed` and before it creates the delivery token ([`crux_driver.ml`](../../../lib/crux/crux_driver.ml) lines 528-541).
`Crux_pull_barrier` sits immediately before and after that write (lines 529-536).
The field starts as `None` at driver creation (lines 217).

Law `D-07` states that the latest committed output is absent before the first commit ([`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 192).
Each commit atomically replaces it with one complete output (`D-07`, same line).
Delivery and terminal state do not replace or clear it (`D-07`, same line).
Law `D-08` states that a pull concurrent with commit publication observes the previous or new complete output and no other value (line 193).
Law `D-09` states that a pull has no delivery or post-commit effect (line 194).
Law `O-01` states that the driver retains the latest committed output and adapters own delivered-output retention (line 215).

The test handle exposes both boundaries ([`lib/crux_test/eta_crux_test.mli`](../../../lib/crux_test/eta_crux_test.mli) lines 73-77).
`Handle.latest_committed_output` forwards to the production driver query ([`lib/crux_test/crux_test_handle.ml`](../../../lib/crux_test/crux_test_handle.ml) lines 96-97).
`Handle.latest_delivered_output` reads the handle shadow field (lines 93-94).
The handle writes that field only after a successful `Delivery.delivered` result (lines 151-160 and 333-344).
`Handle.inject` uses the latest delivered output (lines 133-139).
Law `H-04` states that test injection uses the latest delivered production endpoint ([`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 227).
Law `H-08` states the same committed and delivered split (line 231).

The former `Handle.last_output` is gone ([`public-api.md`](../../../docs/design/eta-crux-v1/public-api.md) lines 813-819).

### Serialized session replacement

`Serialized_session.replace` has this public shape ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 586-619):

| Type | Cases |
|---|---|
| `replace_error` | `Starting`, `Replacement_pending`, `Awaiting_delivery`, `Terminating`, `Closed` |
| `replace_outcome` | `Replaced`, `Stopped`, `Crashed of Failure.t` |

The driver replace body rejects those errors from driver state ([`lib/crux/crux_driver.ml`](../../../lib/crux/crux_driver.ml) lines 240-265):

| Driver state | Error |
|---|---|
| `replacement_pending` | `Replacement_pending` |
| `Closed_done` | `Closed` |
| crash or stop pending states | `Terminating` |
| `Delivering` or `Replacement_delivering` | `Awaiting_delivery` |
| `Running` and `last_output = None` | `Starting` |
| `Running` and `Some output` | accepted |

On the accepted path the driver creates a fresh registry and claims the new candidate ([`crux_driver.ml`](../../../lib/crux/crux_driver.ml) lines 267-291).
It encodes the current output, closes the old session, and sends `Output_deliver` with reason `` `Session_replacement `` (lines 292-338).
It then closes bound requests with `Session_closed` (lines 344-357).
It waits on a completion promise that the later `Output_result` resolves (lines 368-371 and [`crux_driver_serialized.ml`](../../../lib/crux/crux_driver_serialized.ml) lines 314-348).

Law `W-08` closes the old session and waits for its permits.
It installs a complete fresh registry and fences current-output delivery before
advancement ([`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md)
line 207).
Law `W-09` states that session replacement never replays requests (line 208).
Session loss closes bound requests with `Session_closed` and does not crash the root (`W-09`, same line).
Law `W-01` states that identity and serialized bindings produce the same typed observations and shared outcomes for valid input (line 200).

`Session_replacement` forces complete current-output delivery ([`docs/wayfinder/eta-crux-first-principles/issues/10-generic-host-adapter.md`](../../../docs/wayfinder/eta-crux-first-principles/issues/10-generic-host-adapter.md) lines 189-191).
The adapter does not suppress this delivery because the snapshot compares equal (same span).

### Wire frames

The delivery frames are ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 438-487 and [`wire-protocol.md`](../../../docs/design/eta-crux-v1/wire-protocol.md) lines 118-128):

| Frame | Tag | Role |
|---|---|---|
| `Output_deliver` | `output.deliver` | Push committed bytes with `seq`, `reason`, and `output` |
| `Output_result` | `output.result` | Acknowledge that push with `reply_to` and `result` |
| `Crash_notify` | `crash.notify` | Push a portable failure |
| `Crash_result` | `crash.result` | Acknowledge crash notification |

`delivery_reason` is `Advancement` or `Session_replacement` ([`wire-protocol.md`](../../../docs/design/eta-crux-v1/wire-protocol.md) lines 16-18).
Graph time, `Reset`, `Poll`, and the post-commit observer add no wire-frame family (lines 203-206).

Sequence and correlation laws:

| Law | Contract | Gate |
|---|---|---|
| `W-02` | Each direction starts at sequence zero and accepts only the next unsigned 32-bit sequence | `qcheck_wire_sequence` |
| `W-03` | A result must reference one pending command and its exact family | `qcheck_wire_reply_correlation` |
| `W-04` | A structural protocol error closes the session without a reply and changes no application state | `qcheck_malformed_frame_isolation` |
| `W-05` | Operation rejection uses its closed family result and keeps the session open | `qcheck_wire_closed_outcomes` |
| `W-06` | JSON and S-expression envelopes reject noncanonical input | `qcheck_exact_envelope_grammars` |
| `W-07` | A positive `max_frame_bytes` bound applies before decode and after encode. Handles and request tokens contain at most 64 raw bytes | `qcheck_wire_bounds` |

`Serialized_session.receive` applies the frame-size bound before decode ([`lib/crux/crux_wire.ml`](../../../lib/crux/crux_wire.ml) lines 328-331).
`send` applies the bound after encode (lines 405-407).

### Capacity bounds

`Root.create` takes explicit `ingress_capacity` and `request_capacity` ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 665-670).
Law `A-09` states that those capacities are positive, explicit, separate, and never exceeded ([`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 35).
The accepted surface keeps one root-wide bounded FIFO queue ([`issues/18-coherent-accepted-capability-surface.md`](../../../docs/wayfinder/eta-crux-capability-audit/issues/18-coherent-accepted-capability-surface.md) lines 243-258).
It rejects admission classes, reservations, loss, and coalescing (same ticket, lines 63).

`Serialized_session.candidate` takes `max_frame_bytes` ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 598-601).
Verification requires that ingress entries never exceed ingress capacity ([`verification.md`](../../../docs/design/eta-crux-v1/verification.md) lines 369-371).
Pending requests never exceed request capacity (same span).
Serialized handles never exceed live serialized exports (same span).
After session replacement and a full major collection, no old-session handle or removed export remains (same span).

### Failure outcomes

| Outcome | Source | Meaning |
|---|---|---|
| `Root.Rejected Stale_endpoint` | [`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 640-642 | Advancement consumed a stale endpoint and published no output |
| `Root.Rejected Stale_reset` | same span | Advancement consumed a stale reset and published no output |
| `Root.Already_advancing` | lines 644-648 | A second advance ran during advancement |
| `Root.Awaiting_post_commit` | same span | A second advance ran before the token started |
| `Root.Driver_attached` | same span | Direct `Root.advance` after driver attachment |
| `Delivery.Already_completed` | lines 713-725 | A second delivery answer |
| `Failure.origin = Adapter_delivery` | lines 238-246 | Delivery failure after commit |
| `Failure.trigger = Output_delivery` | lines 248-267 | Same delivery-failure record |
| `Serialized_session.Starting` | lines 586-591 | Replace before the first committed output |
| `Serialized_session.Replacement_pending` | same span | A second replace while one replace is live |
| `Serialized_session.Awaiting_delivery` | same span | Replace while a delivery or replacement delivery is pending |
| `Serialized_session.Terminating` | same span | Replace during stop or crash |
| `Serialized_session.Closed` | same span | Replace after close, or replace on an identity binding |
| `receive_error = Session_closed` | lines 582-584 | Peer receive after close |
| `receive_error = Protocol_error` | same span | Peer receive of a structural protocol error |

Law `D-06` states that `Driver_attached` consumes no ingress, reads no clock, records no observer event, and changes no output ([`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 191).

### Deterministic test controls

The handle is a thin owner over the production driver ([`docs/wayfinder/eta-crux-first-principles/issues/12-testing-contract.md`](../../../docs/wayfinder/eta-crux-first-principles/issues/12-testing-contract.md) lines 34-50).
`Handle.create` and `Handle.use` require an explicit `Eta_test.Test_clock.t` ([`eta_crux_test.mli`](../../../lib/crux_test/eta_crux_test.mli) lines 56-71).

| Control | Effect |
|---|---|
| `Handle.frame` | One production poll cycle. It auto-answers `Deliver` through `Test_shell.deliver` ([`crux_test_handle.ml`](../../../lib/crux_test/crux_test_handle.ml) lines 195-244) |
| `Handle.poll` / `Handle.await` | Forward production events. They do not answer a delivery token (lines 297-328) |
| `Handle.delivery_delivered` / `Handle.delivery_failed` | Low-level token answers that keep the delivered-output field correct (lines 333-351) |
| `Test_shell.deliver` | Host delivery callback. A typed error becomes `Delivery.failed` (lines 141-172) |
| `Recording_adapter.delivery_control` | Controlled adapter delivery ([`eta_crux_test.mli`](../../../lib/crux_test/eta_crux_test.mli) lines 267-270) |
| `Handle.advance_time_by` / `advance_time_to` | Clock movement only. They do not advance a root (`GTC-16`, [`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 83) |
| `Crux_pull_barrier` | Private race hook around driver publication ([`lib/crux/crux_pull_barrier.ml`](../../../lib/crux/crux_pull_barrier.ml) lines 1-17) |
| Serialized `peer` receive and `poll_outgoing` | Exact `Output_result` acknowledgment |

Law `H-01` states that a concurrent high-level handle operation returns `Busy` ([`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 224).
Law `H-02` states that one frame performs at most one advancement and stops after complete post-commit admission (line 225).

### Named executable gates

| Law | Gate | File span |
|---|---|---|
| `T-03` | `qcheck_complete_output_per_commit` | [`test/crux/laws/test_eta_crux_laws.ml`](../../../test/crux/laws/test_eta_crux_laws.ml) lines 882-927 |
| `T-04` | `race_commit_atomicity` | registered at [`test/crux/races/test_eta_crux_races.ml`](../../../test/crux/races/test_eta_crux_races.ml) lines 1625-1626 |
| `T-05` | `qcheck_post_commit_fence` | [`test_eta_crux_laws.ml`](../../../test/crux/laws/test_eta_crux_laws.ml) lines 1376-1413 |
| `D-02` | `qcheck_delivery_token` | [`test_eta_crux_laws.ml`](../../../test/crux/laws/test_eta_crux_laws.ml) lines 2016-2056 |
| `D-03` | `race_terminal_vs_delivery` | [`test_eta_crux_races.ml`](../../../test/crux/races/test_eta_crux_races.ml) lines 687-789 |
| `D-06` | `test_driver_attachment_fence` | [`test/crux/unit/test_eta_crux_time_driver.ml`](../../../test/crux/unit/test_eta_crux_time_driver.ml) lines 49-66 |
| `D-07` / `O-01` | `qcheck_latest_committed_output` | [`test_eta_crux_laws.ml`](../../../test/crux/laws/test_eta_crux_laws.ml) lines 3312-3381 |
| `D-08` | `race_pull_vs_commit_both_winners` | [`test_eta_crux_races.ml`](../../../test/crux/races/test_eta_crux_races.ml) lines 1229-1308 |
| `D-09` | `test_pull_does_not_complete_delivery` | [`test_eta_crux_time_driver.ml`](../../../test/crux/unit/test_eta_crux_time_driver.ml) lines 68-88 |
| `F-05` | `test_adapter_delivery_failure` | registered at [`test/crux/unit/test_eta_crux_core.ml`](../../../test/crux/unit/test_eta_crux_core.ml) lines 2264-2265 |
| `O-01` | `test_snapshot_only_observation` | [`test/crux/unit/test_eta_crux_test_surface.ml`](../../../test/crux/unit/test_eta_crux_test_surface.ml) lines 214-269 |
| `O-02` | `test_adapter_commit_boundary` | [`test_eta_crux_test_surface.ml`](../../../test/crux/unit/test_eta_crux_test_surface.ml) lines 276-329 |
| `H-08` | `test_handle_output_boundaries` | [`test_eta_crux_test_surface.ml`](../../../test/crux/unit/test_eta_crux_test_surface.ml) lines 331-361 |
| `W-01` | `conformance_identity_serialized_equivalence` | registered at [`test/crux/conformance/test_eta_crux_conformance.ml`](../../../test/crux/conformance/test_eta_crux_conformance.ml) lines 1000-1001 |
| `W-08` | `race_session_replacement` | [`test_eta_crux_races.ml`](../../../test/crux/races/test_eta_crux_races.ml) lines 791-973 |
| `W-09` | `test_session_loss_requests` | [`test_eta_crux_conformance.ml`](../../../test/crux/conformance/test_eta_crux_conformance.ml) lines 281-386 |

Additional present delivery gates that the law table does not name as the sole owner:

| Gate | Observation |
|---|---|
| `test_driver_delivers_before_post_commit` ([`test_eta_crux_core.ml`](../../../test/crux/unit/test_eta_crux_core.ml) lines 130-157) | Lifecycle work stays gated until `Delivery.delivered` |
| `test_session_loss_settles_pending_delivery` ([`test_eta_crux_conformance.ml`](../../../test/crux/conformance/test_eta_crux_conformance.ml) lines 478-519) | Session close during pending output crashes with `Adapter_delivery` |
| `test_session_loss_settles_replacement` ([`test_eta_crux_conformance.ml`](../../../test/crux/conformance/test_eta_crux_conformance.ml) lines 521-612) | Session close during replacement delivery returns `Crashed` |

Generated classes that the law registry requires:

| Gate | Generated class and observation boundary |
|---|---|
| `qcheck_complete_output_per_commit` | Nonempty bounded action lists forced to contain an equal-model action. Boundary: exact committed-output cardinality and value sequence ([`test_eta_crux_laws.ml`](../../../test/crux/laws/test_eta_crux_laws.ml) lines 883-885) |
| `qcheck_delivery_token` | Integer expected outputs. Boundary: complete output, gated lifecycle, first `Ok ()`, later `Already_completed` (lines 2016-2056) |
| `qcheck_latest_committed_output` | Bounded integer action traces, including output-equal zero actions. Boundary: synchronous pull, delivery events, and token completion (lines 3317-3319) |
| `qcheck_post_commit_fence` | Bounded integer action lists. Boundary: `Awaiting_post_commit` before each token start (lines 1376-1413) |
| `race_pull_vs_commit_both_winners` | Both publication orders. Boundary: previous or new complete integer, never a partial value (lines 1231-1308) |
| `race_session_replacement` | One replacement against current-output redelivery. Boundary: old session closed, sequence restart, fresh handle, stale old handle (lines 791-973) |

### Performance gates

Performance compares fresh baseline and candidate runs in the same environment ([`verification.md`](../../../docs/design/eta-crux-v1/verification.md) lines 314-343).
Checked-in numbers never control a gate (line 317).

Commands:

```sh
nix develop -c bash bench/run.sh --quick --filter '^eta_crux\.'
nix develop -c bash bench/run.sh --filter '^eta_crux\.'
nix develop -c dune exec bench/compare.exe -- --gate \
  baseline-1.json candidate-1.json \
  baseline-2.json candidate-2.json \
  baseline-3.json candidate-3.json
```

If the median increases by more than 15% in two of three complete comparisons, the wall-time row fails (lines 340-342).
If allocated words increase by more than 5% and by more than one word per operation, the allocation row fails (lines 341-342).

Delivery-relevant rows in [`lib/crux/bench/bench_eta_crux.ml`](../../../lib/crux/bench/bench_eta_crux.ml) lines 983-1086:

| Row | Counters |
|---|---|
| `eta_crux.action.complete_advancement` | `commits=1`, `deliveries=1` |
| `eta_crux.incremental.equal_model` | `commits=1`, `dependent_projections=0` |
| `eta_crux.adapter.persistent_output.10000` | `mutated_rows=1` |
| `eta_crux.adapter.persistent_output.100000` | `mutated_rows=1` |
| `eta_crux.driver.identity` | `wire_operations=0` |
| `eta_crux.driver.serialized.0b` | `wire_operations=2`, `payload_bytes=0` |
| `eta_crux.driver.serialized.64b` | `wire_operations=2`, `payload_bytes=64` |
| `eta_crux.driver.serialized.4096b` | `wire_operations=2`, `payload_bytes=4096` |
| `eta_crux.capacity.serialized_handles` | `max_live_exports=1`, `stale_handles=1`, `collected_exports=1` |

The identity row requires zero wire operations ([`verification.md`](../../../docs/design/eta-crux-v1/verification.md) line 361).

## Prior decisions

These resolved records still bind the current delivery contract.

| Record | Decision that still binds |
|---|---|
| First-principles ticket 06 | One advancement processes one event. Commit returns complete output plus a mandatory post-commit token. The driver delivers that output before it starts the token ([`issues/06-advancement-transaction.md`](../../../docs/wayfinder/eta-crux-first-principles/issues/06-advancement-transaction.md) lines 33-79 and 159-169) |
| First-principles ticket 09 | V1 has no typed observation plan. Adapters retain and reconcile complete snapshots ([`issues/09-typed-observation-plan.md`](../../../docs/wayfinder/eta-crux-first-principles/issues/09-typed-observation-plan.md) lines 35-54) |
| First-principles ticket 10 | One delivery token answers one output-delivery question. Replacement delivery success lifts the session-delivery fence. Delivery failure latches `Adapter_delivery` ([`issues/10-generic-host-adapter.md`](../../../docs/wayfinder/eta-crux-first-principles/issues/10-generic-host-adapter.md) lines 114-138 and 189-191) |
| First-principles ticket 12 | The test handle uses the production driver. Low-level delivery completion must go through the handle so delivered output stays correct ([`issues/12-testing-contract.md`](../../../docs/wayfinder/eta-crux-first-principles/issues/12-testing-contract.md) lines 34-50) |
| First-principles ticket 18 | Transport is one closed driver binding. Only the serialized binding creates session administration. The generic driver API does not add `Not_serialized` ([`issues/18-transport-equivalence.md`](../../../docs/wayfinder/eta-crux-first-principles/issues/18-transport-equivalence.md) lines 41-117) |
| First-principles ticket 21 | Delivery and serialized-driver rows belong in the relative performance gate ([`issues/21-performance-gates.md`](../../../docs/wayfinder/eta-crux-first-principles/issues/21-performance-gates.md) lines 14-22 and 49-54) |
| Capability ticket 15 | Adopt `Driver.latest_committed_output`. Adapters retain delivered output. The test handle exposes both boundaries ([`issues/15-pull-observation-of-root-output.md`](../../../docs/wayfinder/eta-crux-capability-audit/issues/15-pull-observation-of-root-output.md) lines 22-83) |
| Capability ticket 18 | One commit fence, one driver owner, and the ordered `Staged` / latest output / `Deliver` / effect-start sequence ([`issues/18-coherent-accepted-capability-surface.md`](../../../docs/wayfinder/eta-crux-capability-audit/issues/18-coherent-accepted-capability-surface.md) lines 44-50 and 260-276) |

Ticket 15 also states that a pull does not answer a delivery token or start
post-commit work (lines 55-58 and 93-99).
It does not change the latest delivered output (same spans).
Current code and `D-09` match that rule.

## Stale claims

These earlier claims no longer match current sources.

| Claim | Where it remains | Current fact |
|---|---|---|
| Production pull of committed output is absent. Test `Handle.last_output` is the only pull | Capability baseline report [`.scratch/research/eta-crux-capability-audit/01-current-eta-crux-capability-baseline.md`](../eta-crux-capability-audit/01-current-eta-crux-capability-baseline.md) lines 229-246 and 343. Provenance report [`02-prior-decision-and-requirement-provenance.md`](../eta-crux-capability-audit/02-prior-decision-and-requirement-provenance.md) lines 198-211. Consumer report [`07-representative-consumer-friction.md`](../eta-crux-capability-audit/07-representative-consumer-friction.md) lines 61 and 94 | `Driver.latest_committed_output` is public ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) line 739). The test handle uses `latest_committed_output` and `latest_delivered_output` ([`eta_crux_test.mli`](../../../lib/crux_test/eta_crux_test.mli) lines 73-77) |
| Graph time and deterministic clock control are missing | Baseline report lines 129-145. Consumer report line 55 | `Time` is public ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 26-41). The handle exposes `advance_time_by` and `advance_time_to` ([`eta_crux_test.mli`](../../../lib/crux_test/eta_crux_test.mli) lines 79-82) |
| Session replacement is `Driver.replace_serialized_session` | First-principles ticket 10 lines 84-100 and 220-223. First-principles ticket 20 lines 71-72 | Public replacement is `Serialized_session.replace` with an admin handle from `Driver.Binding.serialized` ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 616-619 and 691-695) |
| `Hosted.Control` exposes session replacement | First-principles ticket 10 lines 206-223 | `Hosted.Control` exposes only `request_stop` ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 770-774 and [`public-api.md`](../../../docs/design/eta-crux-v1/public-api.md) lines 718-720) |
| The delivery answer does not run root work. The next `poll` or `await` starts the post-commit batch | First-principles ticket 10 lines 116-120 | `Delivery.delivered` starts the post-commit token in the same call ([`crux_driver.ml`](../../../lib/crux/crux_driver.ml) lines 157-169). `qcheck_delivery_token` observes that start ([`test_eta_crux_laws.ml`](../../../test/crux/laws/test_eta_crux_laws.ml) lines 2043-2054) |
| `Driver.create` takes only a root | First-principles ticket 10 lines 90 | `Driver.create` takes a binding and a root ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) line 735) |
| Capability ticket 01 still describes pull as `partial` and graph time as `missing` | [`docs/wayfinder/eta-crux-capability-audit/issues/01-current-eta-crux-capability-baseline.md`](../../../docs/wayfinder/eta-crux-capability-audit/issues/01-current-eta-crux-capability-baseline.md) lines 31-42 | Later ticket 18 records the adopted `Time` and `Driver.latest_committed_output` surface ([`issues/18-coherent-accepted-capability-surface.md`](../../../docs/wayfinder/eta-crux-capability-audit/issues/18-coherent-accepted-capability-surface.md) lines 57-65). Current code implements both |

The baseline report date is 2026-08-10.
Later implementation added `Time`, `Reset`, `Poll`, `Testing`, and the public pull query.
That report is history. It is not the current public surface.

## Gaps

Named law gates for commit, delivery, acknowledgment, pull, and session replacement exist in the current test tree.
The gaps below are coverage holes, not absent law names.

1. **`D-07` terminal coverage is incomplete.**
   Ticket 15 requires `qcheck_latest_committed_output` to cover failed delivery, stop, and crash ([`issues/15-pull-observation-of-root-output.md`](../../../docs/wayfinder/eta-crux-capability-audit/issues/15-pull-observation-of-root-output.md) lines 103-106).
   Law `D-07` states that delivery and terminal state do not replace or clear the latest committed output ([`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 192).
   The current property generates only integer action traces and successful token completion ([`test_eta_crux_laws.ml`](../../../test/crux/laws/test_eta_crux_laws.ml) lines 3312-3381).
   `race_terminal_vs_delivery` preserves the pending token, not the pull query ([`test_eta_crux_races.ml`](../../../test/crux/races/test_eta_crux_races.ml) lines 687-789).
   No inspected gate observes `latest_committed_output` after failed delivery, stop, or crash.

2. **`Serialized_session.replace_error` has no named dedicated gate.**
   The public error family is `Starting`, `Replacement_pending`, `Awaiting_delivery`, `Terminating`, and `Closed` ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 586-591).
   `race_session_replacement` observes the successful `Replaced` path ([`test_eta_crux_races.ml`](../../../test/crux/races/test_eta_crux_races.ml) lines 928-929).
   `test_session_loss_settles_replacement` observes `Crashed` after session loss ([`test_eta_crux_conformance.ml`](../../../test/crux/conformance/test_eta_crux_conformance.ml) lines 595-599).
   The inspected suites do not name a gate for each `replace_error` case.

3. **`W-08` permit-wait is not a separate observation.**
   The law text requires a wait for old-session permits ([`semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) line 207).
   `race_session_replacement` observes old-session close, current-output redelivery, fresh registry, and stale old handles ([`test_eta_crux_races.ml`](../../../test/crux/races/test_eta_crux_races.ml) lines 928-969).
   The inspected replace body closes old requests and waits for the replacement delivery promise ([`crux_driver.ml`](../../../lib/crux/crux_driver.ml) lines 297-371).
   No inspected gate names an export-permit wait as its observation boundary.

4. **Earlier audit reports still describe the pre-pull surface.**
   Those reports are not executable gates.
   A later design ticket that treats them as current facts will copy a stale pull and clock baseline.

No inspected source selects changed-projection delivery, complete-output delivery, notification-then-pull, independent streams, or application effects as the next public interface.
That selection is outside this report.

## Uncertainty

1. This report did not run `dune runtest` or the benchmark compare gate.
   Presence of a named gate is a source fact. Pass or fail status is not a source fact here.
2. The private replace path can wait on export permits through registry or request-close helpers that this report did not fully unwind.
   Gap 3 records that absence of a named observation, not a proven missing wait.
3. Research files under `.scratch/research/eta-crux-capability-audit/` use mixed names.
   This report used the files that the wayfinder tickets link: `01-current-eta-crux-capability-baseline.md`, `02-prior-decision-and-requirement-provenance.md`, `06-eta-substrate-capability-support.md`, `07-representative-consumer-friction.md`, and `bonsai-public-capability-census.md`.
4. First-principles ticket 10 remains provenance for token and replacement fences.
   The public signatures in that ticket are stale. Current `.mli` files and `semantic-laws.md` own the live contract.
