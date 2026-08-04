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
| C-05 | A cutoff receives the published value before the candidate. `always` suppresses every candidate. `never` suppresses none. `phys_equal` uses physical equality. `of_equal` suppresses on `true`. `of_compare` suppresses on zero. A computation cutoff never suppresses committed root-output delivery. | `qcheck_cutoff_boundary` |
| C-06 | `bind` keeps the selected child while the selector preserves its structural occurrence. A changed occurrence disposes the old child before it activates the new child. | `qcheck_bind_child_identity` |

## State machines and ingress

| ID | Law | Gate |
|---|---|---|
| A-01 | One accepted endpoint send appends one message. Acceptance does not run a transition or promise later processing. | `test_endpoint_acceptance_boundary` |
| A-02 | A waiting endpoint send gets FIFO admission. A later nonblocking export cannot overtake it. | `qcheck_ingress_fifo_admission` |
| A-03 | Ingress closure and admission use first-winner arbitration. The losing admission appends nothing and returns `Ingress_closed`. | `race_ingress_close_vs_send_both_winners` |
| A-04 | Endpoint incarnation is checked during advancement. A stale message is consumed and returns `Rejected Stale_endpoint` without a transition. | `test_stale_endpoint_rejection` |
| A-05 | `Endpoint.contramap` preserves target identity, incarnation, lifetime, capacity, and admission outcome. | `qcheck_endpoint_contramap` |
| A-06 | `apply_action` runs once with the committed input and model. Its returned model and effect remain staged until commit. | `qcheck_transition_snapshot` |
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
| T-02 | An empty root returns `Idle` without stabilization or output delivery. | `test_idle_is_inert` |
| T-03 | Start and each accepted application action commit one complete root output, including an output equal to the prior output. | `qcheck_complete_output_per_commit` |
| T-04 | Model, graph, scopes, lifecycle manifests, output, and effect eligibility commit in one root-frame publication. A pre-publication failure preserves the previous frame. A later defect cannot roll back and crashes the root before output delivery. | `race_commit_atomicity` |
| T-05 | A commit returns one mandatory post-commit token. No later advancement starts before that token starts. | `qcheck_post_commit_fence` |
| T-06 | A post-commit token starts at most once. Stop or crash changes its work but never invalidates the token. | `race_batch_start_exactly_once` |
| T-07 | Batch admission first registers new work behind closed gates. It then requests removed-subtree cancellation, opens new sources, and releases the transition effect. | `test_post_commit_phase_order` |
| T-08 | Removal cancellation requests complete before new work starts. Old cleanup does not need to settle before new work starts. | `test_cleanup_overlap` |
| T-09 | A transition effect whose owner is disposed by its own commit never starts. | `test_self_disposing_effect` |
| T-10 | Stop closes ingress, discards buffered actions, replaces a pending start, and settles the complete work tree before `Closed`. | `test_stop_from_each_driver_phase` |

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

## Failure and driver

| ID | Law | Gate |
|---|---|---|
| F-01 | An interruption-only owned-work cause is normal cleanup. Every other escaping cause latches root crash. | `qcheck_cause_classification` |
| F-02 | The first fatal record remains primary. Later records append as secondary in observation order without invented causal structure. | `race_failure_observation_order` |
| F-03 | Crash latching closes ingress, discards queued actions, wakes the driver, and forbids later application advancement. | `test_crash_latch` |
| F-04 | Commit and fatal detection use first-winner arbitration. A fatal winner rolls back staging. A commit winner preserves output and converts its batch to teardown. | `race_commit_vs_crash_both_winners` |
| F-05 | Output-delivery failure cannot roll back a commit. It suppresses ordinary batch work and records `Adapter_delivery`. | `test_adapter_delivery_failure` |
| F-06 | Crash detection precedes teardown. Final settlement contains the same primary, all secondary records, and `teardown_settled = true`. | `test_crash_detection_and_settlement` |
| F-07 | Cleanup failure changes normal stop to crash. During crash, cleanup failure appends secondary evidence. | `test_cleanup_failure_precedence` |
| F-08 | Diagnostic hooks run only during fatal record construction. Hook failure appends `Crash_handler` evidence and leaves that snapshot absent. | `test_diagnostic_hook_failure` |
| D-01 | One driver operation performs at most one advancement and reports every stale rejection. | `qcheck_driver_one_advancement` |
| D-02 | Output delivery completes before post-commit admission. A delivery token accepts one answer. | `qcheck_delivery_token` |
| D-03 | Stop or crash while delivery is pending closes ingress but preserves that committed delivery. Terminal work starts after its answer. | `race_terminal_vs_delivery` |
| D-04 | Hosted acquisition and release errors stay outside root failure. Hosted interruption settles the root and releases the binding. | `test_hosted_resource_boundary` |

## Serialized transport

| ID | Law | Gate |
|---|---|---|
| W-01 | Identity and serialized bindings produce the same typed observations and shared outcomes for valid input. | `conformance_identity_serialized_equivalence` |
| W-02 | Each direction starts sequence zero and accepts only the exact next unsigned 32-bit sequence. Every frame consumes one sequence. | `qcheck_wire_sequence` |
| W-03 | A result must reference one pending command and its exact family. | `qcheck_wire_reply_correlation` |
| W-04 | A structural protocol error closes the session without a reply and changes no application state. | `qcheck_malformed_frame_isolation` |
| W-05 | Operation rejection uses its closed family result and keeps the session open. | `qcheck_wire_closed_outcomes` |
| W-06 | JSON rejects duplicate, unknown, missing, and wrongly typed fields. S-expressions reject nesting and wrong arity. Both reject noncanonical base64url. | `qcheck_exact_envelope_grammars` |
| W-07 | A positive `max_frame_bytes` bound applies before decoding and after encoding. Handles and request tokens contain at most 64 raw bytes. | `qcheck_wire_bounds` |
| W-08 | Session replacement closes the old session, waits for its permits, installs a complete fresh registry, and fences current-output delivery before advancement. | `race_session_replacement` |
| W-09 | Session replacement never replays requests. Session loss closes bound requests with `Session_closed` and does not crash the root. | `test_session_loss_requests` |
| W-10 | A remote result never contains a local decoder diagnostic, Eta cause, graph identity, model, or action. | `qcheck_wire_redaction` |

## Observation and telemetry

| ID | Law | Gate |
|---|---|---|
| O-01 | The complete committed root output is the only application observation. Adapters own snapshot retention and reconciliation. | `test_snapshot_only_observation` |
| O-02 | The driver delivers output after commit and before post-commit work. Adapter callbacks never run during stabilization. | `test_adapter_commit_boundary` |
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
