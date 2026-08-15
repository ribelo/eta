# Laws and deterministic test controls

Type: grilling
Status: resolved
Blocked by: 09, 10, 11

## Question

Which laws and deterministic controls can prove the complete contract?

Give every accepted law one named executable gate and one exact observation
boundary. Define generated classes and required discriminating coverage.

Add deterministic controls for commit, delivery, acknowledgment, write failure,
adapter failure, attachment, replacement, removal, and capacity pressure.

Control both legal winners for each race. Compare identity and serialized typed
observations. Follow the law registry rules in `AGENTS.md`.

## Answer

Every accepted law gets one named executable gate. The laws enter
`docs/design/eta-crux-v1/semantic-laws.md`. Three new families hold the
projection laws. `PRJ` holds core semantics. `PRW` holds wire contracts. `PRB`
holds session replacement and bootstrap. Stale output-delivery laws are
rewritten in place to their projection form.

### Registry conventions

- Each row carries one claim, one named gate, one observation boundary, and
  one binding tag.
- One gate can serve several rows when it discriminates every cited claim.
- Each generated gate states its generated class and its required
  discriminating coverage.
- The binding tag is `both`, `serialized-only`, or `identity-only`.
- A race gate controls both legal winners when both outcomes are valid.
- A gate finishes with an empty fiber census when no background work is
  legitimate.
- A gate failure prints the counterexample.
- Laws about application codecs and comparators stand as application
  obligations. Generated gates prove them for every codec and comparator that
  the test suite uses. Key session-independence has no possible runtime check
  for arbitrary typed keys, so it stays an application obligation.

### Observation boundaries

Gates observe these exact points:

- **Adapter delivery log** (identity binding): the typed batches and snapshots
  that the recording adapter accepted.
- **Wire peer frame log** (serialized binding): the decoded frames at the
  session peer.
- **Committed pull**: `Driver.latest_committed_snapshot`.
- **Delivered shadow**: the delivered-state shadow of the test handle. This
  shadow is test-only.
- **Post-commit observer**: staged, started, settled, and discarded events.
- **Driver outcomes**: `Root.advance` results, driver results, and
  `Failure.Packed_cause` projections.
- **Session peer state**: open or closed, with sequence positions.

### Amended laws

Projection delivery replaces complete root-output delivery. These existing
laws are rewritten in place.

| ID | Change | Gate |
|---|---|---|
| T-03 | A commit publishes one projection image. The batch can be empty. | `qcheck_projection_image_per_commit` (renamed) |
| T-04 | The root-frame publication includes the image. A pre-publication failure preserves the previous frame. | `race_commit_atomicity` (amended) |
| D-02 | Projection delivery completes before post-commit admission. The delivery token accepts one answer. | `qcheck_delivery_token` (amended) |
| D-03 | Stop or crash preserves a pending projection delivery or bootstrap. Terminal work starts after its answer. | `race_terminal_vs_delivery` (amended) |
| D-07 | The latest committed snapshot is absent before the first commit. Each commit atomically replaces it. Delivery and terminal state do not replace or clear it. | `qcheck_latest_committed_snapshot` plus `test_latest_committed_snapshot_retained_after_failed_delivery`, `test_latest_committed_snapshot_retained_after_stop`, and `test_latest_committed_snapshot_retained_after_crash` (new) |
| D-08 | A pull concurrent with commit publication observes the previous or new complete snapshot. | `race_pull_vs_commit_both_winners` (amended) |
| D-09 | A pull has no delivery or post-commit effect. | `test_pull_does_not_complete_delivery` (amended) |
| O-01 | One commit publishes one projection image. The driver retains the committed snapshot. The recipient retains the delivered snapshot. | `test_snapshot_only_observation` (amended) plus the D-07 gates |
| O-02 | Delivery runs after commit and before post-commit work. Adapter callbacks never run during stabilization. | `test_adapter_commit_boundary` (amended) |
| F-04 | Commit and fatal detection keep first-winner arbitration under projection publication. | `race_commit_vs_crash_both_winners` (amended) |
| F-05 | Projection-delivery failure cannot roll back a commit. It latches `Adapter_delivery` and does not retry. The trigger is `Projection_delivery`. | `test_adapter_delivery_failure` (amended) |
| W-01 | Projection observations join the identity-serialized equivalence surface. | `conformance_projection_transport_equivalence` (new, shared) |
| W-02, W-03, W-06, W-07 | Sequences, reply correlation, envelope grammars, and bounds cover the projection frames. | Generated classes extended to projection frames. No duplicated rows. |
| W-08 | Replacement follows [Session replacement and bootstrap](11-session-replacement-and-bootstrap.md). The permit wait gets a named observation. | `race_session_replacement` (amended) plus `test_session_replacement_permit_wait` (new) |

### New PRJ family: core semantics

Binding tag: `both` for every row. PRJ-30 is compile-level.

| ID | Law | Gate |
|---|---|---|
| PRJ-01 | `publish` returns its candidate locally. The cutoff changes only the outward image. | `qcheck_projection_publish_local_value` (generated value and cutoff sequences) |
| PRJ-02 | Kind generativity: equal arguments never merge descriptor instances. | `test_projection_kind_generativity` |
| PRJ-03 | Catalog rejects a duplicate descriptor, a duplicate wire name, a bad name grammar, and a name over 128 bytes. An empty list is valid. Rejection is `Invalid_argument` before any root exists. | `qcheck_projection_catalog_rejection` (descriptor lists with one injected violation; all four rejection classes and acceptance observed) |
| PRJ-04 | One catalog can serve several roots. Committed state, capacity, and incarnation allocation stay per-root. | `test_projection_catalog_shared_roots` |
| PRJ-05 | `projection_capacity` must be positive. | `test_projection_capacity_positive` |
| PRJ-06 | Identity is one kind instance and one key. `key_compare = 0` defines equivalence. One relation controls identity, lookup, collision, and order. | `qcheck_projection_identity_equivalence` (key populations with equivalent and non-equivalent pairs) |
| PRJ-07 | Key codec laws: equivalent keys both encode or both return `encode_error`. Equivalent keys produce identical bytes. Non-equivalent keys produce different bytes. Decoding encoded bytes returns an equivalent key. | `qcheck_projection_key_codec_laws` (suite codecs; all four claims) |
| PRJ-08 | Value codec round-trip: decoding an encoded value returns a value equal under `value_equal`. | `qcheck_projection_value_codec_roundtrip` (suite codecs) |
| PRJ-09 | `key_compare` is a stable total order. | `qcheck_projection_key_compare_total_order` (suite comparators; generated key triples) |
| PRJ-10 | One final committed image contains at most one active attachment per identity. Two active attachments collide even with equal values. | `qcheck_projection_identity_collision` (images with collision injection) |
| PRJ-11 | The retained incarnation continues only when one structural occurrence publishes one identity across consecutive committed images. The five ending conditions end it. | `qcheck_projection_incarnation_continuity` (structural sequences; all five endings discriminated) |
| PRJ-12 | An incarnation replacement is adjacent `Removed` then `Attached`. It is valid and not a collision. | Shared with the PRJ-17 gate |
| PRJ-13 | Incarnation allocation: positive unsigned 64-bit counter, zero invalid, unique and never reused per root, deterministic batch order. A failed advancement consumes no incarnation values. | `qcheck_projection_incarnation_allocation` (commit sequences with injected preflight failures) |
| PRJ-14 | Counter exhaustion is `Incarnation_exhausted`, a pre-commit structural failure. | `test_projection_incarnation_exhausted` (harness seeds the counter near maximum) |
| PRJ-15 | Incarnations are opaque: comparable, not constructible, no wire access. | Compile gate plus `test_projection_incarnation_opaque` |
| PRJ-16 | The cutoff suppresses `Changed` only. A suppressed or equal candidate never replaces the retained value. | `qcheck_projection_cutoff_retention` |
| PRJ-17 | The cutoff cannot suppress `Attached` or `Removed`. Batch validity: the five transition forms, incarnation matching, at most two updates per identity, only adjacent `Removed` then `Attached`. | `qcheck_projection_batch_validity` (generated batches with suppress-always cutoffs and replacements) |
| PRJ-18 | A `key_compare` or cutoff exception is a pre-commit defect. The prior commit is preserved and no delivery runs. Origin is `Transition` and trigger is `Projection_preflight`, with the local cause retained. | `qcheck_projection_cutoff_defect` (raising cutoffs and comparators at a chosen call) |
| PRJ-19 | Capacity independently bounds active identities, batch records, and bootstrap entries. | `qcheck_projection_capacity_bounds` (exact boundary and one-over per dimension) |
| PRJ-20 | A replacement consumes two update records. Eta Crux never chunks, drops, or coalesces records. A capacity-one replacement fails with `Projection_capacity_exceeded`. | `test_projection_capacity_one_replacement` plus the PRJ-19 property |
| PRJ-21 | The closed preflight family is fatal: `Root.advance` returns `Failed`, and `Packed_cause.projection_preflight` returns the exact typed error. It returns `None` for every other cause. | `qcheck_projection_preflight_cause` (one violation per case plus foreign causes) |
| PRJ-22 | A preflight failure preserves the prior image, emits no delivery, and starts no post-commit work. | Shared with the PRJ-13 and PRJ-21 gates |
| PRJ-23 | One commit is one immutable snapshot plus one ordered batch. An observer sees the prior or new complete commit, never a partial one. | `race_commit_atomicity` (shared) |
| PRJ-24 | Intermediate recomputations never enter the commit. The batch reflects the prior committed state and the final stabilized state only. | `qcheck_projection_commit_endpoints_only` (multi-recompute advancements) |
| PRJ-25 | The initial commit emits `Attached` for every active projection. An empty initial image emits an empty batch. Every successful commit causes exactly one delivery and requires exactly one acknowledgment, empty batches included. | `test_projection_initial_commit` plus `qcheck_projection_delivery_per_commit` (delivery counting, empty batches included) |
| PRJ-26 | Canonical order is catalog declaration order, then `key_compare` order. Snapshot folds, batch folds, and wire entries agree. | `qcheck_projection_canonical_order` |
| PRJ-27 | Snapshots and batches are opaque, with typed lookup and a rank-2 existential fold. Batch lookup returns the ordered update list. | `test_projection_typed_lookup_fold` |
| PRJ-28 | The recipient retains the latest delivered snapshot. No delivered snapshot exists before the first accepted delivery. An accepted empty initial batch establishes an empty delivered snapshot. A pending delivery leaves the prior delivered snapshot in place. A failed delivery never advances delivered state. | `test_projection_delivered_shadow` (delivered shadow) |
| PRJ-29 | The recipient installs the complete new observation before it acknowledges success. | `test_projection_install_before_ack` |
| PRJ-30 | No production query exposes delivered state. The shadow is test-only. | Compile gate (no such API) |

### New PRW family: wire contracts

Binding tag: `serialized-only` for every row except PRW-20, which is
`identity-only`.

#### Common rows

| ID | Law | Gate |
|---|---|---|
| PRW-01 | Each serialized entry carries the kind wire name, encoded key, incarnation, the value unless `Removed`, and the update tag in a batch. | `qcheck_projection_wire_entry_structure` |
| PRW-02 | Wire entries use canonical order. The shell rejects any other order and never sorts or repairs. | `qcheck_projection_wire_order_rejection` (generated permutations) |
| PRW-03 | The `count` field equals the exact item count. | `qcheck_projection_wire_count_exactness` (mismatch injection) |
| PRW-04 | Canonical unsigned decimal integers, nonzero incarnations, and canonical base64url bytes are required. | Extends the W-06 and W-07 generated classes |
| PRW-05 | JSON objects are closed with fixed field order. `Removed` omits the value. S-expressions stay flat with exact arity. | Extends the W-06 generated class |
| PRW-06 | A `projection.result` references its delivery sequence. One result acknowledges one delivery. | Extends the W-03 generated class |
| PRW-07 | A failed diagnostic is redacted UTF-8 of at most 1,024 bytes. A longer or invalid diagnostic closes the session. Eta Crux never truncates it. | `qcheck_projection_result_diagnostic` |
| PRW-08 | The eight payload-rejection conditions return `failed` and keep the session open. | `qcheck_projection_payload_rejection` (one violation per generated batch; all eight classes discriminated) |
| PRW-09 | Structural errors close the session: malformed envelope, bad sequence, bad correlation, invalid diagnostic. | Extends the W-04 generated class |
| PRW-10 | `max_frame_bytes` applies before decode and after encode. An oversize push frame closes the session with `Frame_too_large` and fails the delivery. No split and no truncation. | `test_projection_push_frame_too_large` plus a qcheck boundary property |
| PRW-11 | The shell decodes each key, encodes it again, and requires byte equality. It uses `key_compare` to detect duplicate identities. | `qcheck_projection_wire_key_canonicality` |
| PRW-12 | An encode error after commit keeps the commit published and fails the complete delivery with `Adapter_delivery` and trigger `Projection_delivery`. | `test_projection_encode_failure_key` and `test_projection_encode_failure_value` |
| PRW-13 | A codec exception is a defect with the local cause retained. No conversion into a typed codec error. | `test_projection_codec_raise_defect` |
| PRW-14 | Local diagnostics never enter frames. A shell decode failure returns one bounded redacted diagnostic. The diagnostic can name the kind and field, never payload data. | Extends the W-10 generated class |
| PRW-15 | The shell validates every transition against its prior delivered snapshot, plus count and continuation. A capacity mismatch fails the complete delivery atomically. No fallback. | `qcheck_projection_shell_transition_validation` |
| PRW-16 | Adapter atomicity: decode and validate before host mutation, install as one transaction, keep the prior delivered state on failure, and advance delivered state before `accepted`. | `test_projection_adapter_atomic_install` (failure during install) |
| PRW-17 | No catalog exchange, fingerprint, or negotiation exists. Unknown tags are rejected. | Shared with the W-06 gate |
| PRW-18 | After interface selection, the protocol keeps exactly one profile. No negotiation, fallback, or dormant tags for the rejected profiles. | Gate lands in the selection change (see Profile coverage) |
| PRW-19 | Value codecs run inside the committed export-registry fence. A handle request for an absent export raises. The commit stays published and the delivery fails as `Adapter_delivery`. | `test_projection_value_handle_fence` |
| PRW-20 | Identity delivery performs no codec work and allocates no remote handles. | `test_projection_identity_zero_codec` |

#### Complete snapshot push profile

| ID | Law | Gate |
|---|---|---|
| PRW-21 | `projection.deliver` carries the complete ordered active snapshot for advancement and for session replacement. Zero entries are valid and still get one result. | `qcheck_projection_sp_deliver_snapshot` |

#### Changed complete-value batch push profile

| ID | Law | Gate |
|---|---|---|
| PRW-22 | `Advancement` requires `Updates` and `Session_replacement` requires `Bootstrap`. Any other pairing is an invalid application payload. | `qcheck_projection_bp_reason_content_pairing` |

#### Notification followed by bounded pull profile

| ID | Law | Gate |
|---|---|---|
| PRW-23 | `projection.notify` carries reason, content, and exact `item_count`. Its sequence is the frozen commit reference. Only one notification can be pending. The frozen observation stays valid until its final result or session closure. | `qcheck_projection_pl_notify_fence` |
| PRW-24 | A pull carries the notification sequence, a null or exact-next cursor, and a positive limit. Zero is valid for `item_count` and invalid for `limit`. | `qcheck_projection_pl_pull_validation` |
| PRW-25 | A cursor belongs to one notification and is single-use. An earlier, repeated, or foreign cursor is invalid. | `qcheck_projection_pl_cursor` (cursor misuse classes) |
| PRW-26 | A page is the greatest nonempty ordered prefix inside the limit and `max_frame_bytes`. Entries never split. One oversized entry gives `Entry_too_large`. | `qcheck_projection_pl_page_maximality` plus `test_projection_pl_entry_too_large` |
| PRW-27 | Unknown notifications, invalid cursors, and invalid limits keep the session open. They never look like valid empty pages. | Shared with the PRW-24 and PRW-25 gates |
| PRW-28 | A zero-item notification is already complete. The shell can acknowledge it without a pull. | `test_projection_pl_zero_item_notify` |
| PRW-29 | The shell can fail at any point after notification, and failure releases the frozen observation. Acceptance is valid only after complete retrieval, validation, and installation. Early acceptance closes the session. | `test_projection_pl_fail_releases_frozen` and `test_projection_pl_early_accept_closed` |

### New PRB family: session replacement and bootstrap

Binding tag: `serialized-only` for every row.

| ID | Law | Gate |
|---|---|---|
| PRB-01 | The bootstrap is the retained committed snapshot in canonical order. Replacement performs no stabilization, commit, or application replay. Identities removed before replacement are absent. | `test_projection_bootstrap_source` |
| PRB-02 | Session replacement preserves active incarnation values. | `test_projection_bootstrap_incarnation_continuity` |
| PRB-03 | The recipient installs the bootstrap as one atomic replacement. An identity absent from the bootstrap leaves the delivered state. | `test_projection_bootstrap_atomic_install` |
| PRB-04 | The replacement sequence runs in order: preflight, fresh registration, bootstrap encode, old-session close, bootstrap send, permit settlement, result wait, fence lift. | `test_projection_replacement_step_order` (ordered observation log) |
| PRB-05 | The bootstrap is always the first delivery on the new session. Every later advancement batch follows it in order. | `test_projection_bootstrap_first_delivery` |
| PRB-06 | The preflight family is closed: `Starting`, `Replacement_pending`, `Awaiting_delivery`, `Terminating`, and `Closed`. | `test_replace_error_starting`, `test_replace_error_replacement_pending`, `test_replace_error_awaiting_delivery`, `test_replace_error_terminating`, `test_replace_error_closed` (five new gates) |
| PRB-07 | A pending pull-profile notification is an unacknowledged delivery and returns `Awaiting_delivery`. Session closure releases the frozen observation. | Shared with `test_replace_error_awaiting_delivery` |
| PRB-08 | Replacement on an identity binding returns `Closed`. | Shared with `test_replace_error_closed` |
| PRB-09 | `Starting` means no committed image. An empty initial commit permits replacement with an empty bootstrap. | `test_projection_replace_empty_bootstrap` |
| PRB-10 | A commit with no live session publishes, fails delivery immediately, latches `Adapter_delivery`, and crashes the root. | `test_projection_commit_no_session` |
| PRB-11 | Replacement is legal in the window between session loss and the next commit. This is the recovery path. | `test_projection_replace_in_loss_window` |
| PRB-12 | Replacement never waits for in-flight post-commit effects. A bootstrap admits no post-commit work. | `test_projection_bootstrap_no_post_commit` (held post-commit effect) |
| PRB-13 | A failed bootstrap result or new-session loss during bootstrap latches `Adapter_delivery` and returns `Crashed`. Eta Crux does not retry. | `test_projection_bootstrap_failure_crashes` and `test_projection_bootstrap_session_loss` |
| PRB-14 | Root stop during the bootstrap wait returns `Stopped`. Root crash returns `Crashed`. Terminal work waits for the pending answer. | `race_terminal_vs_delivery` (amended, shared) |
| PRB-15 | Commit and replacement use first-winner arbitration at driver-operation granularity. The bootstrap carries the prior or the new complete committed snapshot, never a mix. | `race_replacement_vs_commit_both_winners` (new) |
| PRB-16 | Advancement runs only in driver state `Running`. No advancement runs while a replacement delivery is pending. | `test_projection_advancement_fence` |
| PRB-17 | The bootstrap entry count cannot exceed `projection_capacity`. Replacement adds no new preflight failure. | Shared with the PRJ-19 gate |
| PRB-18 | An oversize push bootstrap closes the new session with `Frame_too_large`, fails the delivery, latches `Adapter_delivery`, and returns `Crashed`. The pull profile pages the bootstrap. An entry that cannot fit returns `Entry_too_large` and the shell returns a failed final result. | `test_projection_bootstrap_frame_too_large` and `test_projection_bootstrap_paged` |
| PRB-19 | Initial attach has no bootstrap. The first commit's `Attached` advancement is the starting observation. | `test_projection_initial_attach_no_bootstrap` |

### Harness laws

The new projection harness module in `eta_crux_test` carries these laws in the
existing H family.

| ID | Law | Gate |
|---|---|---|
| H-09 | The responder answers each delivery at most once. A second answer fails the test. | `test_projection_responder_one_answer` |
| H-10 | A held delivery admits no post-commit work until it is answered. | `test_projection_held_delivery_fences_post_commit` (post-commit observer) |
| H-11 | Equivalent scripts produce equivalent typed observations on both bindings. | Shared with the conformance gate |

### Deterministic controls

The projection harness in `eta_crux_test` supplies these controls uniformly
across both bindings:

- **Delivery responder**: accept, fail with a diagnostic, or hold pending,
  scripted per delivery. One answer per delivery.
- **Write-failure injection**: fail the next write, or fail every write from a
  chosen point.
- **Adapter failure injection**: fail host installation during apply.
- **Codec-failure injection**: `encode_error`, `decode_error`, or raise at a
  chosen call, per kind and per field.
- **Replacement trigger**: start session replacement at a chosen driver state.
- **Session-loss injection**: lose the session at a chosen point.
- **Incarnation-counter seed**: seed the root counter near exhaustion for
  PRJ-14.
- **Capacity pressure**: scenario helpers that drive attachments to exact
  capacity boundaries.

Commit, injection, attachment, and time controls already exist in the test
handle and stay unchanged. Removal is a scenario composition through ordinary
structural change. Raw-frame driving stays available for structural wire
gates.

### Race gates

Each race gate controls both legal winners through the harness responder and
trigger controls:

- `race_commit_atomicity` (amended)
- `race_commit_vs_crash_both_winners` (amended)
- `race_terminal_vs_delivery` (amended; bootstrap included)
- `race_pull_vs_commit_both_winners` (amended)
- `race_replacement_vs_commit_both_winners` (new)

Deterministic outcomes are not races and use ordinary gates: replacement
during a pending delivery returns `Awaiting_delivery`, a commit with no live
session latches `Adapter_delivery`, and replacement in the loss window
recovers.

### Identity and serialized comparison

`conformance_projection_transport_equivalence` runs generated commit, removal,
replacement, and failure sequences on both bindings. It requires identical
typed observations at the adapter delivery log, committed pull, delivered
shadow, and driver outcomes. Each registry row carries its binding tag, so the
serialized-only and identity-only surfaces are explicit.

### Inherited gate gaps closed

1. D-07 terminal pull observations: three new deterministic gates retain the
   committed snapshot after failed delivery, stop, and crash.
2. The five `replace_error` outcomes: five named gates under PRB-06.
3. The W-08 permit wait: `test_session_replacement_permit_wait`.

### Profile coverage

All three protocol profiles receive complete gates in this answer. [Select the
public interface and seam](14-select-public-interface-and-seam.md) stays a
pure selection. The selection change deletes the two rejected profiles with
their laws and gates. The PRW-18 profile-fixity gate becomes executable in
that same change.

### Relationship to later tickets

[Performance and zero-cost gates](13-performance-and-zero-cost-gates.md) is
now unblocked. [Implementation plan](15-implementation-plan.md) must name
every registry row, gate, and control from this answer, and must schedule the
profile deletion. The implementation adds registry rows for every law-bearing
claim in the changed `.mli` files in the same change, as `AGENTS.md` requires.

No new ticket is necessary.
