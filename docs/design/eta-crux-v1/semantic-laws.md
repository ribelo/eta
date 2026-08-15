# Eta Crux V1 semantic laws

## Registry rules

This file is the only normative behavior registry for Eta Crux V1. Other design
files define types, ownership, and gate procedures. They do not add behavior.

Each law has one planned executable gate. Gate names are stable implementation
targets. A gate must become executable in the same change that implements its
law. A property gate must state its generated class and observation boundary.

## Computation and identity

| ID | Law | Gate |
|---|---|---|
| C-01 | A description is inert. Only `Root.create` instantiates it. | `test_description_is_inert` |
| C-02 | Each root instantiates a private graph. No live graph value can enter description composition. | `test_roots_are_isolated` and compile-fail `root_is_not_description` |
| C-03 | Reuse of one allocating description node in one structural scope shares one cell. Separate constructor calls create separate cells. | `qcheck_description_identity` |
| C-04 | `map`, `both`, and `bind` observe only committed dependencies. A failed stabilization publishes no derived value. | `qcheck_committed_dependencies_only` |
| C-05 | A cutoff receives the published value before the candidate. `always` suppresses every candidate. `never` suppresses none. `phys_equal` uses physical equality. `of_equal` suppresses on `true`. `of_compare` suppresses on zero. A computation cutoff does not control projection delivery. | `qcheck_cutoff_boundary` |
| C-06 | `bind` keeps the selected child while the selector preserves its structural occurrence. A changed occurrence disposes the old child before it activates the new child. | `qcheck_bind_child_identity` |

## State machines and ingress

| ID | Law | Gate |
|---|---|---|
| A-01 | One accepted endpoint send appends one message. Acceptance does not run a transition or promise later processing. | `test_endpoint_acceptance_boundary` |
| A-02 | A waiting endpoint send gets FIFO admission. A later nonblocking export cannot overtake it. | `qcheck_ingress_fifo_admission` |
| A-03 | Ingress closure and admission use first-winner arbitration. The losing admission appends nothing and returns `Ingress_closed`. | `race_ingress_close_vs_send_both_winners` |
| A-04 | Endpoint incarnation is checked during advancement. A stale message is consumed and returns `Rejected Stale_endpoint` without a transition. | `test_stale_endpoint_rejection` |
| A-05 | `Endpoint.contramap` preserves target identity, incarnation, lifetime, capacity, and admission outcome. | `qcheck_endpoint_contramap` |
| A-06 | `apply_action` runs once with the committed input and model. Its returned model and optional effect remain staged until commit. `None` stages no effect. | `qcheck_transition_snapshot` |
| A-07 | A transition exception commits no model or graph change and starts no staged effect. | `test_transition_rollback` |
| A-08 | A staged effect is typed-infallible. Application success and failure return as later actions. | compile gates `staged_effect_rejects_typed_error` and `admission_must_be_handled` |
| A-09 | Ingress and request capacities are positive, explicit, separate, and never exceeded. | `qcheck_capacity_bounds` |

## Keyed children

| ID | Law | Gate |
|---|---|---|
| K-01 | `Order.compare` defines key identity. The direct persistent map type defines output order. | `qcheck_assoc_key_order` |
| K-02 | Continuous key presence preserves the keyed scope, child graph, model, data source, and endpoint incarnation. | `qcheck_assoc_continuous_presence` |
| K-03 | A same-key data candidate that the data cutoff does not suppress updates the stable data source. It does not rebuild or reset the child. | `qcheck_assoc_data_update` |
| K-04 | Committed key removal disposes the incarnation. Re-entry of the same key creates fresh state and endpoints. | `qcheck_assoc_remove_reenter` |
| K-05 | One commit deactivates all removed keyed children before it activates any added keyed child. | `qcheck_assoc_lifecycle_order` |
| K-06 | A failed keyed edit preserves the previous map, children, and endpoints. A provisional addition never activates. | `qcheck_assoc_rollback` |
| K-07 | Keyed reconciliation and child-only changes satisfy the public `Eta_signal_map` change-proportional bounds. Live keyed storage is linear in live keys. | existing `Eta_signal_map` keyed complexity gate plus `bench_eta_crux_assoc` |

## Advancement and post-commit work

| ID | Law | Gate |
|---|---|---|
| T-01 | One advancement selects at most one event. Control events have priority. Application messages remain FIFO. | `qcheck_one_event_advancement` |
| T-02 | An empty root returns `Idle` without stabilization or projection delivery. | `test_idle_is_inert` |
| T-03 | Start and each accepted application action commit one projection image. The update batch can be empty. | `qcheck_projection_image_per_commit` |
| T-04 | The model, graph, scopes, lifecycle manifests, projection image, and effect eligibility commit in one root-frame publication. A pre-publication failure preserves the previous frame. | `race_commit_atomicity` |
| T-05 | A commit returns one mandatory post-commit token. No later advancement starts before that token starts. | `qcheck_post_commit_fence` |
| T-06 | A post-commit token starts at most once. Stop or crash changes its work but never invalidates the token. | `race_batch_start_exactly_once` |
| T-07 | Batch admission first registers new work behind closed gates. It then requests removed-subtree cancellation, opens new sources, and concurrently releases eligible transition, reset, and Poll effects. | `test_post_commit_phase_order` and `test_poll_post_commit_phase_order` |
| T-08 | Removal cancellation requests complete before new work starts. Old cleanup does not need to settle before new work starts. | `test_cleanup_overlap` |
| T-09 | A transition effect whose owner is disposed by its own commit never starts. | `test_self_disposing_effect` |
| T-10 | Stop closes ingress, discards buffered actions, replaces a pending start, and settles the complete work tree before `Closed`. | `test_stop_from_each_driver_phase` |

## Graph time

| ID | Law | Gate |
|---|---|---|
| GTC-01 | Initial advancement captures one `Eta.Spi.Expert.Clock.t`. The root uses that token for its complete lifetime. | `qcheck_graph_time_initial_binding` |
| GTC-02 | After terminal selection, one advance attempt with active graph-time nodes reads the clock at most once. Each committed nonterminal advancement uses one shared sample. | `qcheck_graph_time_shared_sample` |
| GTC-03 | A later nonterminal advancement with a different clock terminally fails with `Runtime_mismatch`. | `test_graph_time_runtime_mismatch` |
| GTC-04 | Only active and necessary graph-time nodes contribute deadlines. Committed disposal removes their deadlines before the next driver wait. | `qcheck_graph_time_structural_ownership` |
| GTC-05 | `Driver.poll` processes an already-due deadline. A due deadline also makes `Driver.await` continue without ingress. | `qcheck_graph_time_deadline_wake` |
| GTC-06 | `Driver.await` cancels the losing wait. An ingress wake causes a new deadline calculation before the next wait. | `qcheck_graph_time_await_race` |
| GTC-07 | Crash and stop precede `Clock_due`. `Clock_due` precedes FIFO ingress. | `qcheck_graph_time_event_priority` |
| GTC-08 | One clock sample produces at most one `Clock_due` advancement. The event preserves every queued ingress item. | `qcheck_graph_time_due_coalescing` |
| GTC-09 | A committed one-shot timer retires its deadline. A committed periodic timer installs its next future deadline. | `qcheck_graph_time_timer_progress` |
| GTC-10 | Each committed advancement gives `now` the shared clock sample. An unrelated Action does not reset the activation-aligned `every` cadence. | `qcheck_graph_time_now_cadence` |
| GTC-11 | `deadline` changes from false to true once in one active interval. Its timestamp is future and belongs to the root clock at activation. | `qcheck_graph_time_deadline` |
| GTC-12 | `after` measures from successful activation. A failed activation installs no deadline. | `qcheck_graph_time_after_activation` |
| GTC-13 | `interval` starts at zero. It catches up arithmetically, saturates at `max_int`, and does not replay missed ticks. | `qcheck_graph_time_interval_catch_up` |
| GTC-14 | A successful `Clock_due` event produces one projection image and one mandatory post-commit token. | `qcheck_graph_time_commit_fence` |
| GTC-15 | One `Driver.poll` or `Driver.await` operation performs at most one advancement. | `qcheck_graph_time_driver_bound` |
| GTC-16 | Moving test time does not advance Eta Crux or trigger Poll. A later `frame` or `drain` observes due work through the production driver. | `test_graph_time_handle_separation` |
| GTC-17 | Test movement rejects backward targets with `Invalid_argument`. `Eta.Duration.t` is nonnegative, so a negative constructor input reaches the handle as zero. Zero movement is a no-op. | `test_graph_time_handle_validation` |
| GTC-18 | Identity and serialized bindings observe the same clock advancements and projection images. | `qcheck_graph_time_transport_equivalence` |
| GTC-19 | Each root or driver clock read compares against the last successful read. Regression, internal overflow, a past dynamic deadline, or mismatch terminally fails the root. | `test_graph_time_dynamic_failures` |
| GTC-20 | A clock mismatch or regression uses `Graph_clock` and `Clock_sample`. Timer faults preserve the event trigger, and due-time faults use `Clock_due`. | `test_graph_time_failure_attribution` |
| GTC-21 | Eta Crux does not clamp time, ignore a timer, change clocks, or use wall time as a fallback. | `test_graph_time_no_fallback` |
| GTC-22 | `now`, `after`, and `interval` reject non-positive durations with `Invalid_argument`. `Time.add` returns its documented arithmetic result. | `test_graph_time_static_validation` |

## Structural reset

| ID | Law | Gate |
|---|---|---|
| RST-01 | A reset reaches exactly the active state-machine descendants of its selected scope. An outer reset reaches nested scopes, but an inner reset does not reach its parent. | `qcheck_reset_scope_boundary` |
| RST-02 | Every reset callback observes the same pre-reset committed frame. One advancement publishes all reset models and graph changes or none. | `qcheck_reset_snapshot_atomicity` |
| RST-03 | Default reset restores `default_model`. A custom reset can return a default, preserved, or non-idempotent model. Repeated triggers run once each and never coalesce. | `qcheck_reset_default_custom` |
| RST-04 | Continuous keyed children preserve identity. Removed children dispose, and new children start with defaults. | `qcheck_reset_dynamic_children` |
| RST-05 | Reset triggers and endpoint Actions preserve accepted FIFO order. Each active no-change or empty reset commits one projection image. | `qcheck_reset_ingress_order` |
| RST-06 | Reset-scope disposal and reset advancement admit both legal winners. A reset winner commits before disposal. A disposal winner returns `Stale_reset` without a reset transition. | `race_reset_vs_disposal_both_winners` |
| RST-07 | A callback exception preserves the prior frame, starts no reset effect, and records `Structural_reset` with only the failing cell and model diagnostic. | `test_reset_callback_rollback` |
| RST-08 | A commit stages the exact reset-effect inventory. Effects obey owner disposal, concurrent sibling start, and the standard settlement classes. | `qcheck_reset_effect_lifecycle` |
| RST-09 | One reset authority stays stable across input and model changes. Disposal makes it stale, and re-entry creates a fresh authority. | `qcheck_reset_authority_incarnation` |
| RST-10 | A root with no reset scope performs no reset traversal and allocates no reset authority, item, or observation record during ordinary advancement. | `structural_reset_disabled_allocation` |

## Poll run coordination

| ID | Law | Gate |
|---|---|---|
| POLL-01 | Each Poll incarnation publishes its selected starting value and has empty run history. | `qcheck_poll_starting_incarnation` |
| POLL-02 | Successful activation stages one run after delivery. One advancement stages at most one automatic run with the latest committed input. | `qcheck_poll_activation_and_coalescing` |
| POLL-03 | `input_cutoff` alone decides whether an active candidate input triggers work. Inactive candidates create no history. | `qcheck_poll_input_cutoff` |
| POLL-04 | Each run uses the provider from its triggering commit. A provider-only change does not trigger work. | `qcheck_poll_provider_sampling` |
| POLL-05 | Each refresh invocation appends one ordinary FIFO item or returns `Ingress_closed`. Refreshes never coalesce. | `qcheck_poll_manual_refresh_admission` |
| POLL-06 | Completion items share bounded FIFO ingress with Actions. One advancement consumes at most one item. | `qcheck_poll_completion_fifo` |
| POLL-07 | A completion changes its local value only when its order exceeds every prior committed completion order. | `qcheck_poll_committed_run_order` |
| POLL-08 | A newer equal completion advances the order fence even when result propagation is suppressed. | `qcheck_poll_result_cutoff_order_fence` |
| POLL-09 | Run order is strict and never reused within one incarnation. A new incarnation starts a fresh order. | `qcheck_poll_run_order` |
| POLL-10 | Run-order exhaustion rolls back the complete advancement and records a transition failure with the active trigger. | `qcheck_poll_run_order_overflow` |
| POLL-11 | Completion and disposal admit both legal winners. Disposal-first requests cancellation without waiting and fences every old result. | `race_poll_completion_vs_disposal_both_winners` |
| POLL-12 | Projection delivery precedes Poll start. Transition, reset, and Poll effects have no relative start or settlement order. | `test_poll_post_commit_phase_order` |
| POLL-13 | A Poll body cannot expose a typed error. | compile gate `poll_effect_rejects_typed_error` |
| POLL-14 | Poll defects use `Owned_work` and `Poll_effect`. Interruption-only disposal creates no failure. | `qcheck_poll_failure_attribution` |
| POLL-15 | The observer inventories each Poll run in its triggering commit and records one lifecycle path. | `qcheck_post_commit_effect_observer_poll_lifecycle` |
| POLL-16 | Clock-event priority stays ahead of FIFO ingress when a clock commit triggers Poll. | `qcheck_poll_clock_priority` |
| POLL-17 | Identity and serialized drivers produce the same Poll behavior after boundary validation. | `qcheck_poll_transport_equivalence` |
| POLL-18 | A graph without Poll allocates no Poll state, run order, endpoint, hook, observer identity, or observer event. | `poll_disabled_allocation` |

## Post-commit effect observation

| ID | Law | Gate |
|---|---|---|
| PCO-01 | Every successful commit records one `Staged` event with the next commit index and exact transition, reset, and Poll effect inventory. | `qcheck_post_commit_effect_observer_inventory` |
| PCO-02 | Each observed effect records exactly one accepted terminal path. | `qcheck_post_commit_effect_observer_lifecycle` |
| PCO-03 | Each effect obeys its lifecycle order. Different effects have no relative start or settlement order. | `qcheck_post_commit_effect_observer_order` |
| PCO-04 | `poll` and `drain` preserve event-position order and remove each returned event once. | `qcheck_post_commit_effect_observer_fifo` |
| PCO-05 | Attaching the canonical observer changes no production result. | `qcheck_post_commit_effect_observer_transparency` |
| PCO-06 | With no observer, successful commits allocate no observation value or queue entry. | `post_commit_effect_observer_disabled_allocation` |
| PCO-07 | Overlapping observer-consumer operations have one claim winner. A loser raises `Invalid_argument` before queue inspection or removal. | `race_post_commit_effect_observer_read_both_winners` |

## Lifetime and sources

| ID | Law | Gate |
|---|---|---|
| L-01 | A child is active or disposed. Committed absence invalidates its endpoints immediately. Later presence creates a new incarnation. | `qcheck_active_disposed_states` |
| L-02 | One lifecycle node starts at most one program in one active interval. Value changes do not restart it. | `qcheck_lifecycle_once_per_interval` |
| L-03 | Work belongs to its structural scope. Removed subtrees settle children before parent finalizers. Sibling subtrees settle concurrently. | `test_structural_scope_settlement` |
| L-04 | Eta resource finalizers are the only deactivation cleanup mechanism. Root shutdown preserves all finalizer causes. | `test_lifecycle_resource_cleanup` |
| S-01 | A source-spec candidate suppressed by its cutoff preserves the producer and updates committed mappers. An accepted candidate creates a fresh incarnation. | `qcheck_source_spec_identity` |
| S-02 | A source reports ready after its admission path opens. Its long-lived producer starts only after that report. | `test_source_opening_barrier` |
| S-03 | New source openings run concurrently. The transition effect waits for every opening success or typed opening failure. | `test_concurrent_source_opening` |
| S-04 | Each item and terminal outcome uses the latest committed mapper and enters through ordinary endpoint admission. | `qcheck_source_latest_mapper` |
| S-05 | Completion or typed failure produces one terminal action and no automatic restart. Disposal interruption produces no terminal action. | `qcheck_source_terminal_outcome` |

## Exports and requests

| ID | Law | Gate |
|---|---|---|
| E-01 | One export node keeps one generation for an active interval. Absence revokes it. Re-entry creates a new generation. | `qcheck_export_generation` |
| E-02 | Active recomputation updates the endpoint binding behind retained local and remote values. The codec remains fixed. | `qcheck_export_rebinding` |
| E-03 | Local invocation performs no handle, registry, codec, frame, or sequence operation. | `conformance_identity_zero_wire` |
| E-04 | Invocation and structural change use a per-export permit. The first winner pins its binding or returns the new availability state. | `race_export_permit_vs_commit_both_winners` |
| E-05 | Decoder or endpoint-mapper exceptions latch `Export_dispatch`, close ingress, release the permit, and re-raise. | `test_export_callback_defect` |
| R-01 | A request has one structural owner and accepts at most one resolution. Later resolution returns `Not_pending`. | `qcheck_request_first_resolution` |
| R-02 | Outbound requests wait for request capacity. Inbound admission reports request capacity and ingress capacity separately. | `qcheck_request_capacity` |
| R-03 | Dispatch acceptance means that response and cancellation paths are installed. It does not mean that host work finished. | `test_request_dispatch_fence` |
| R-04 | Cancellation closes request identity before peer notification. Cancellation and dispatch acceptance use first-winner arbitration. | `race_cancel_vs_dispatch_both_winners` |
| R-05 | Resolution and cancellation use first-winner arbitration. The loser observes `Not_pending`. | `race_resolve_vs_cancel_both_winners` |
| R-06 | Owner disposal, root termination, or session closure closes pending requests with its exact closure reason. | `qcheck_request_closure_reasons` |
| R-07 | Root settlement waits for local terminal handoff acceptance. It never waits for foreign acknowledgment or consumption. | `test_request_terminal_handoff_fence` |
| R-08 | Descriptor mismatch does not claim an event. Constructing an unrun handler effect does not claim it. The first executed matching handler or total dispatcher claims before user work, and typed failure retains the claim. | `test_outbound_request_round_trip` |
| R-09 | Handler claim and cancellation use first-winner arbitration. Cancellation-first starts no host work. Claim-first delivers the exact closure reason to `on_cancel`. | `race_cancel_vs_dispatch_both_winners` |
| R-10 | An outbound request encode error returns `Requester.Encode_failed`, allocates no request identity, consumes no request capacity, and emits no driver event. | `test_requester_encode_failed` |
| R-11 | A host-operation response decode error returns `Requester.Decode_failed`, closes only that request, and keeps the session open. | `test_requester_decode_failed` |
| R-12 | An inbound request-export response encode error returns `Responder.Encode_failed` and keeps that request pending. | `test_responder_encode_failed` |

## Failure and driver

| ID | Law | Gate |
|---|---|---|
| F-01 | An interruption-only owned-work cause is normal cleanup. Every other escaping cause latches root crash. | `qcheck_cause_classification` |
| F-02 | The first fatal record remains primary. Later records append as secondary in observation order without invented causal structure. | `race_failure_observation_order` |
| F-03 | Crash latching closes ingress, discards queued actions, wakes the driver, and forbids later application advancement. | `test_crash_latch` |
| F-04 | Commit and fatal detection use first-winner arbitration. A fatal winner rolls back staging. A commit winner preserves the projection image and converts its batch to teardown. | `race_commit_vs_crash_both_winners` |
| F-05 | Projection-delivery failure cannot roll back a commit. It latches `Adapter_delivery`, discards ordinary work, and does not retry. The trigger is `Projection_delivery`. | `test_adapter_delivery_failure` |
| F-06 | Crash detection precedes teardown. Final settlement contains the same primary, all secondary records, and `teardown_settled = true`. | `test_crash_detection_and_settlement` |
| F-07 | Cleanup failure changes normal stop to crash. During crash, cleanup failure appends secondary evidence. | `test_cleanup_failure_precedence` |
| F-08 | Diagnostic hooks run only during fatal record construction. Hook failure appends `Crash_handler` evidence and leaves that snapshot absent. | `test_diagnostic_hook_failure` |
| D-01 | One driver operation performs at most one advancement and reports every stale rejection. | `qcheck_driver_one_advancement` |
| D-02 | Projection delivery completes before post-commit admission. A delivery token accepts one answer. | `qcheck_delivery_token` |
| D-03 | Stop or crash preserves a pending projection delivery or bootstrap. Terminal work starts after its answer. | `race_terminal_vs_delivery` |
| D-04 | Hosted acquisition and release errors stay outside root failure. Hosted interruption settles the root and releases the binding. | `test_hosted_resource_boundary` |
| D-05 | Attachment atomically claims an unstarted root and an unused binding. Each conflicting race has one winner. A loser raises `Invalid_argument` and leaves each otherwise-unused argument available. | `race_driver_attachment_both_winners` |
| D-06 | After attachment, direct `Root.advance` returns `Error Driver_attached`. It consumes no ingress, reads no clock, records no observer event, and changes no projection image. | `test_driver_attachment_fence` |
| D-07 | The latest committed snapshot is absent before the first commit. Each commit atomically replaces it. Delivery and terminal state do not replace or clear it. | `qcheck_latest_committed_snapshot`, `test_latest_committed_snapshot_retained_after_failed_delivery`, `test_latest_committed_snapshot_retained_after_stop`, and `test_latest_committed_snapshot_retained_after_crash` |
| D-08 | A pull concurrent with commit publication observes the previous or new complete snapshot. | `race_pull_vs_commit_both_winners` |
| D-09 | A pull has no delivery or post-commit effect. | `test_pull_does_not_complete_delivery` |

## Serialized transport

| ID | Law | Gate |
|---|---|---|
| W-01 | Identity and serialized bindings produce the same projection observations and shared outcomes for valid input. | `conformance_projection_transport_equivalence` |
| W-02 | Each direction starts sequence zero and accepts only the exact next unsigned 32-bit sequence. Every frame, including projection frames, consumes one sequence. | `qcheck_wire_sequence` |
| W-03 | A result must reference one pending command and its exact family. This rule includes `Projection_result`. | `qcheck_wire_reply_correlation` |
| W-04 | A structural protocol error closes the session without a reply and changes no application state. Projection envelope errors use this rule. | `qcheck_malformed_frame_isolation` |
| W-05 | Operation rejection uses its closed family result and keeps the session open. | `qcheck_wire_closed_outcomes` |
| W-06 | JSON rejects duplicate, unknown, missing, and wrongly typed fields. S-expressions reject nesting and wrong arity. Both reject noncanonical base64url, including projection fields. | `qcheck_exact_envelope_grammars` |
| W-07 | A positive `max_frame_bytes` bound applies before decoding and after encoding. This rule includes projection frames. Handles and request tokens contain at most 64 raw bytes. | `qcheck_wire_bounds` |
| W-08 | Session replacement closes the old session, waits for its permits, installs a complete fresh registry, and fences projection delivery before advancement. | `race_session_replacement` and `test_session_replacement_permit_wait` |
| W-09 | Session replacement never replays requests. Session loss closes bound requests with `Session_closed` and does not crash the root. | `test_session_loss_requests` |
| W-10 | A remote result never contains a local decoder diagnostic, Eta cause, graph identity, model, action, key, or projection value. | `qcheck_wire_redaction` |

## Projection core

| ID | Law | Gate |
|---|---|---|
| PRJ-01 | `Projection.publish` returns its candidate locally. The kind cutoff changes only the outward image. | `qcheck_projection_publish_local_value` |
| PRJ-02 | Each `Kind.define` call creates a distinct kind. Equal arguments do not merge kinds. | `test_projection_kind_generativity` |
| PRJ-03 | `Catalog.create` accepts an empty list. It rejects a repeated kind, a repeated name, an invalid name, and a name longer than 128 bytes. | `qcheck_projection_catalog_rejection` |
| PRJ-04 | One catalog can serve several roots. Each root owns its committed state, capacity, and incarnation counter. | `test_projection_catalog_shared_roots` |
| PRJ-05 | `projection_capacity` must be positive. | `test_projection_capacity_positive` |
| PRJ-06 | One kind instance and one key form an identity. `key_compare left right = 0` defines key equivalence for all identity operations. | `qcheck_projection_identity_equivalence` |
| PRJ-07 | Equivalent keys have equal successful encodings or equal encode failure. Non-equivalent keys have different successful encodings. Decoding an encoding returns an equivalent key. | `qcheck_projection_key_codec_laws` |
| PRJ-08 | Decoding an encoded value returns a value that is equal under `value_equal`. | `qcheck_projection_value_codec_roundtrip` |
| PRJ-09 | `key_compare` is a stable total order. | `qcheck_projection_key_compare_total_order` |
| PRJ-10 | One committed image contains at most one active attachment for each identity. Two active attachments are a collision, including equal values. | `qcheck_projection_identity_collision` |
| PRJ-11 | An incarnation continues only when one structural occurrence publishes one identity in consecutive commits. Absence, re-entry, kind change, key change, or owner change ends it. | `qcheck_projection_incarnation_continuity` |
| PRJ-12 | A same-identity owner replacement produces adjacent `Removed` and `Attached` updates. | `qcheck_projection_batch_validity` |
| PRJ-13 | A root allocates positive unsigned 64-bit incarnation values in canonical order. It does not reuse values or consume a value after failed preflight. | `qcheck_projection_incarnation_allocation` |
| PRJ-14 | Incarnation-counter exhaustion is the preflight error `Incarnation_exhausted`. | `test_projection_incarnation_exhausted` |
| PRJ-15 | An incarnation is comparable and opaque. The public API has no constructor or wire conversion. | compile gate and `test_projection_incarnation_opaque` |
| PRJ-16 | A cutoff suppresses only `Changed`. A suppressed candidate keeps the prior complete retained value. | `qcheck_projection_cutoff_retention` |
| PRJ-17 | A cutoff does not suppress `Attached` or `Removed`. Each identity has one of the five valid batch transition forms. | `qcheck_projection_batch_validity` |
| PRJ-18 | A comparator or cutoff exception preserves the prior commit. It causes no delivery and uses origin `Transition` with trigger `Projection_preflight`. | `qcheck_projection_cutoff_defect` |
| PRJ-19 | `projection_capacity` independently bounds active identities, ordinary batch records, and bootstrap entries. | `qcheck_projection_capacity_bounds` |
| PRJ-20 | A replacement uses two batch records. A capacity-one replacement fails without chunking, dropping, or coalescing an update. | `test_projection_capacity_one_replacement` and `qcheck_projection_capacity_bounds` |
| PRJ-21 | The preflight family is exactly `Unknown_kind`, `Identity_collision`, `Projection_capacity_exceeded`, and `Incarnation_exhausted`. `Packed_cause.projection_preflight` returns the exact case. | `qcheck_projection_preflight_cause` |
| PRJ-22 | Failed preflight preserves the prior image. It starts no delivery or ordinary post-commit work. | `qcheck_projection_incarnation_allocation` and `qcheck_projection_preflight_cause` |
| PRJ-23 | One commit contains one immutable complete snapshot and one ordered batch. An observer sees no partial commit. | `race_commit_atomicity` |
| PRJ-24 | A commit contains the final stabilized projection image. It contains no intermediate recomputation or local root result. | `qcheck_projection_commit_endpoints_only` |
| PRJ-25 | The initial commit attaches each active identity. An empty image has an empty batch. Every commit creates one acknowledged delivery. | `test_projection_initial_commit` and `qcheck_projection_delivery_per_commit` |
| PRJ-26 | Snapshot entries, batch updates, and wire items use catalog order and then key order. | `qcheck_projection_canonical_order` |
| PRJ-27 | Snapshots and batches are opaque. Typed lookup and existential folds expose complete entries and ordered updates. | `test_projection_typed_lookup_fold` |
| PRJ-28 | The recipient retains the accepted delivered snapshot. Pending or failed delivery does not change it. An accepted empty initial batch installs an empty snapshot. | `test_projection_delivered_shadow` |
| PRJ-29 | The recipient installs the complete new observation before successful acknowledgment. | `test_projection_install_before_ack` |
| PRJ-30 | Production code has no delivered-state query. The delivered shadow is a test-only surface. | compile gate |

## Projection wire contract

| ID | Law | Gate |
|---|---|---|
| PRW-01 | A wire entry contains the kind name, key, incarnation, and value. A batch update also contains its update tag. `Removed` has no value. | `qcheck_projection_wire_entry_structure` |
| PRW-02 | Wire items use canonical order. A recipient rejects another order and does not repair it. | `qcheck_projection_wire_order_rejection` |
| PRW-03 | An S-expression item count equals the exact item count. | `qcheck_projection_wire_count_exactness` |
| PRW-04 | Incarnations use nonzero canonical unsigned decimal. Bytes use canonical unpadded base64url. | `qcheck_exact_envelope_grammars` and `qcheck_wire_bounds` |
| PRW-05 | JSON projection objects are closed and use fixed field order. S-expression projection forms are flat and have exact arity. | `qcheck_exact_envelope_grammars` |
| PRW-06 | `Projection_result` references its one pending `Projection_deliver`. | `qcheck_wire_reply_correlation` |
| PRW-07 | A failed result contains valid UTF-8 of at most 1,024 bytes. An invalid diagnostic closes the session without truncation. | `qcheck_projection_result_diagnostic` |
| PRW-08 | An invalid projection payload fails atomically and keeps the session open. The rejection classes cover kind, key, incarnation, order, identity, transition, codec, and capacity. | `qcheck_projection_payload_rejection` |
| PRW-09 | A malformed envelope, sequence, correlation, or result diagnostic closes the session. | `qcheck_malformed_frame_isolation` |
| PRW-10 | `max_frame_bytes` applies before decode and after encode. An oversize projection closes the session and fails the delivery without splitting. | `test_projection_push_frame_too_large` and `qcheck_projection_frame_size_boundary` |
| PRW-11 | A recipient decodes and re-encodes each key. It requires byte equality and uses `key_compare` for duplicate detection. | `qcheck_projection_wire_key_canonicality` |
| PRW-12 | A key or value encode error after commit preserves the commit and fails the complete delivery with trigger `Projection_delivery`. | `test_projection_encode_failure_key` and `test_projection_encode_failure_value` |
| PRW-13 | A codec exception remains a local defect cause. Eta Crux does not convert it to a typed codec error. | `test_projection_codec_raise_defect` |
| PRW-14 | A local diagnostic does not enter a frame. A recipient diagnostic is bounded and redacted. | `qcheck_wire_redaction` |
| PRW-15 | A recipient checks every transition against its delivered snapshot. It rejects a count or capacity mismatch atomically. | `qcheck_projection_shell_transition_validation` |
| PRW-16 | An adapter decodes and checks the complete delivery before host mutation. Failed installation keeps the prior delivered state. | `test_projection_adapter_atomic_install` |
| PRW-17 | The protocol exchanges no catalog, fingerprint, codec metadata, or profile selection. | `qcheck_exact_envelope_grammars` |
| PRW-18 | The protocol has one changed complete-value batch-push profile. It has no negotiation, fallback, or dormant profile tag. | `qcheck_exact_envelope_grammars` and [Wire protocol](wire-protocol.md) |
| PRW-19 | Value codecs run inside the committed export-registry fence. A missing export handle raises after commit and fails delivery. | `test_projection_value_handle_fence` |
| PRW-20 | Identity delivery runs no projection codec and allocates no remote handle. | `test_projection_identity_zero_codec` |
| PRW-22 | `Advancement` requires `Updates`. `Session_replacement` requires `Bootstrap`. Other pairs are invalid. | `qcheck_projection_bp_reason_content_pairing` |

## Projection bootstrap

| ID | Law | Gate |
|---|---|---|
| PRB-01 | A bootstrap comes from the latest committed snapshot. Replacement does not stabilize, commit, or replay the application. | `test_projection_bootstrap_source` |
| PRB-02 | Session replacement preserves active incarnation values. | `test_projection_bootstrap_incarnation_continuity` |
| PRB-03 | A bootstrap atomically replaces the complete delivered snapshot. An absent identity leaves delivered state. | `test_projection_bootstrap_atomic_install` |
| PRB-04 | Replacement runs preflight, fresh registration, bootstrap encode, old-session close, send, permit settlement, result wait, and fence lift in order. | `test_projection_replacement_step_order` |
| PRB-05 | A bootstrap is the first delivery on a new session. Later advancement batches follow it. | `test_projection_bootstrap_first_delivery` |
| PRB-06 | The replacement preflight family is exactly `Starting`, `Replacement_pending`, `Awaiting_delivery`, `Terminating`, and `Closed`. | `test_replace_error_starting`, `test_replace_error_replacement_pending`, `test_replace_error_awaiting_delivery`, `test_replace_error_terminating`, and `test_replace_error_closed` |
| PRB-07 | An unacknowledged delivery blocks replacement with `Awaiting_delivery`. | `test_replace_error_awaiting_delivery` |
| PRB-08 | An identity binding has no replacement session. A replacement request returns `Closed`. | `test_replace_error_closed` |
| PRB-09 | No committed image gives `Starting`. An empty committed image permits an empty bootstrap. | `test_projection_replace_empty_bootstrap` |
| PRB-10 | A commit without a live session remains published. Delivery fails, latches `Adapter_delivery`, and crashes the root. | `test_projection_commit_no_session` |
| PRB-11 | A replacement can recover the interval after session loss and before the next commit. | `test_projection_replace_in_loss_window` |
| PRB-12 | Replacement does not wait for an in-flight post-commit effect. A bootstrap admits no post-commit work. | `test_projection_bootstrap_no_post_commit` |
| PRB-13 | Bootstrap rejection or new-session loss latches `Adapter_delivery`, returns `Crashed`, and does not retry. | `test_projection_bootstrap_failure_crashes` and `test_projection_bootstrap_session_loss` |
| PRB-14 | Stop or crash during the bootstrap wait preserves the pending answer fence. | `race_terminal_vs_delivery` |
| PRB-15 | Commit and replacement use first-winner arbitration. A bootstrap contains the prior or new complete committed snapshot. | `race_replacement_vs_commit_both_winners` |
| PRB-16 | Advancement runs only in `Running`. It does not run while replacement delivery is pending. | `test_projection_advancement_fence` |
| PRB-17 | Bootstrap entry count cannot exceed `projection_capacity`. Replacement adds no new preflight family. | `qcheck_projection_capacity_bounds` |
| PRB-18 | An oversize bootstrap closes the new session, latches `Adapter_delivery`, and returns `Crashed`. | `test_projection_bootstrap_frame_too_large` |
| PRB-19 | Initial session attachment has no bootstrap. The first commit sends `Attached` advancement updates. | `test_projection_initial_attach_no_bootstrap` |

## Observation and telemetry

| ID | Law | Gate |
|---|---|---|
| O-01 | One successful commit publishes one projection image. The driver retains the committed snapshot. The recipient retains the delivered snapshot. | `test_snapshot_only_observation` and the D-07 gates |
| O-02 | The driver delivers a projection after commit and before post-commit work. Adapter callbacks never run during stabilization. | `test_adapter_commit_boundary` |
| O-03 | Telemetry contains only the fixed names, categories, and redacted attributes in [Verification](verification.md). | `test_telemetry_contract` |
| O-04 | Disabled telemetry changes no semantic observation and creates no point, attribute, span, or retained state. | `conformance_disabled_telemetry` |

## Test-harness laws

| ID | Law | Gate |
|---|---|---|
| H-01 | One test handle has exclusive production-driver ownership. A concurrent high-level operation returns `Busy`. | `test_handle_exclusive_ownership` |
| H-02 | One frame performs at most one advancement and stops after complete post-commit admission. | `test_frame_boundary` |
| H-03 | A bounded drain stops at idle, closure, or its positive step limit. A limit result leaves the handle usable. | `qcheck_bounded_drain` |
| H-04 | Test injection uses the latest delivered production endpoint. It never writes directly to ingress. | `test_incoming_uses_endpoint` |
| H-05 | Controlled effects and sources use FIFO observation and one-shot completion. Real Eta cancellation decides interruption. | `qcheck_controlled_dependencies` |
| H-06 | Handle finalization settles the root. An unobserved crash fails the test with complete settlement. | `test_handle_bracket_cleanup` |
| H-07 | Each handle movement delegates once to the supplied clock claim and does not advance a root. Overlapping movements on one shared clock have one winner. | `race_handle_shared_clock_movement_both_winners` |
| H-08 | The handle exposes the committed snapshot through the production driver. It exposes a test-only delivered shadow after successful delivery. Test injection uses that shadow. | `test_handle_projection_boundaries` |
| H-09 | The projection responder answers each delivery at most once. A second answer fails the test. | `test_projection_responder_one_answer` |
| H-10 | A held projection delivery admits no post-commit work until it has an answer. | `test_projection_held_delivery_fences_post_commit` |
| H-11 | Equivalent scripts produce equivalent typed observations on identity and serialized bindings. | `conformance_projection_transport_equivalence` |

## Test-clock movement

| ID | Law | Gate |
|---|---|---|
| TC-01 | Overlapping movement operations on one test clock have one claim winner. A loser raises `Invalid_argument`, changes no time, and wakes no sleeper. | `race_test_clock_movement_both_winners` |
| TC-02 | `advance_to` compares and moves under one claim. It rejects a backward target and wakes each due sleeper before it releases the claim. | `test_clock_advance_to_is_monotonic` |
