# Implementation plan

Type: grilling
Status: resolved
Blocked by: 14

## Question

What is the smallest implementation plan for the approved interface?

Name every affected Eta package, public module, private module, wire codec,
test module, benchmark, design document, glossary entry, and law-registry row.

Order the work by executable gates. Identify compile-time migrations and
deletions. Do not add compatibility paths or implement the capability.

## Answer

Sequencing: one recording task and three gated changes. Every change lands
with `dune build @install` and `dune runtest --force` green; change 2 also
keeps `dune build @bench` compiling.

### Change 1 — fallible `Codec` (independent breaking migration)

- `lib/crux/eta_crux.mli` + `crux_*.ml`: `Codec` gains `encode_error`;
  `encode` returns `(bytes, encode_error) result`. `Requester.error` gains
  `Encode_failed of Codec.encode_error` and `Decode_failed of
  Codec.decode_error`. `Responder.error` becomes `Not_pending | Encode_failed
  of Codec.encode_error`.
- Behaviors per [Identity, codec, and wire
  contract](10-identity-codec-and-wire-contract.md) §Shared codec effects:
  outbound request encode error allocates no request identity, consumes no
  capacity, and emits no driver event; response decode error closes only that
  request; inbound response encode error leaves the request pending; inbound
  request decode stays `Malformed_payload` (unchanged).
- Registry: three new R-family rows in the same change as the `.mli` prose —
  R-10 (`test_requester_encode_failed`), R-11
  (`test_requester_decode_failed`), and R-12
  (`test_responder_encode_failed`). Every `Codec.make` caller
  compile-migrates (including the E-02, E-03, and W-10 gates); their prose is
  unchanged.

### Task T0 — record the pre-projection baseline

After change 1 and before change 2: run a full `nix develop -c bash
bench/run.sh` and commit the result file to `bench/results/`. This is
PRF-08's final pre-projection full-suite result and the regression
reference. Recording after change 1 isolates the projection delta from the
codec delta.

### Change 2 — the replacement (single atomic semantic change)

Ordered bottom-up; each item lands with its executable gates.

1. **Failure trigger.** `Output_delivery` becomes `Projection_delivery` in
   `crux_failure.ml`, `eta_crux.mli` `Failure`, and
   `crux_portable_failure.ml` (byte 11 remapped; no format shim).
   Portable-failure round-trip gates migrate.
2. **Public `Projection` module** in `eta_crux.mli`, implemented by new
   private `lib/crux/crux_projection.ml` and `.mli`: `Incarnation` (opaque),
   `Kind` (generative `define`), `Catalog` (`create` plus four rejection
   classes), `Snapshot`, `Batch`, `Commit`, `delivery`, `preflight_error`,
   `publish`. Gates: PRJ-01 to PRJ-09, PRJ-15 (compile plus named test),
   PRJ-27, PRJ-30 (compile). [Exact projection read and delivery
   signatures](18-exact-projection-read-and-delivery-signatures.md) owns the
   exact `Snapshot`, `Batch`, `Commit`, lookup, and fold signatures.
3. **Commit machinery** in `crux_projection.ml` with seam edits in
   `crux_root.ml` and `crux_engine.ml`: preflight validation, incarnation
   allocation (unsigned 64-bit root counter, deterministic batch order, no
   consumption on failure), cutoff application, update classification
   (replacement is adjacent `Removed` then `Attached`), canonical order,
   snapshot retention, endpoints-only commit. Gates: PRJ-06, PRJ-10 to
   PRJ-14, PRJ-16 to PRJ-26.
4. **Driver delivery fences** in `crux_driver.ml` and `crux_driver_base.ml`:
   one delivery per commit (empty included), one-answer token, acknowledgment
   admits post-commit work, failure latches `Adapter_delivery` with trigger
   `Projection_delivery`, terminal fence, `latest_committed_snapshot`.
   Gates: PRJ-23, PRJ-25, PRJ-28, PRJ-29; amended D-02, D-03, D-08, D-09,
   O-01, O-02, F-04, F-05; D-07 amended plus its three inherited-gap gates
   (`test_latest_committed_snapshot_retained_after_failed_delivery`,
   `..._after_stop`, `..._after_crash`).
5. **Serialized binding**: `lib/crux_wire_common/protocol_model.ml` and
   `frame_conversion.ml` gain `Projection_deliver` (`projection_content =
   Updates | Bootstrap`) and `Projection_result`; `Deliver_output` and
   `Output_result` are deleted. `lib/crux_json/protocol.ml` and
   `lib/crux_sexp/protocol.ml` gain the exact grammars from [Identity, codec,
   and wire contract](10-identity-codec-and-wire-contract.md).
   `crux_driver_serialized.ml`: entry encode in canonical order,
   `max_frame_bytes` gives `Frame_too_large`, result correlation,
   payload-rejection versus structural split, export-registry fence for value
   codecs. Public `Wire.Frame` in `eta_crux.mli` and `crux_wire.ml` is
   updated. Gates: PRW-01 to PRW-20 and PRW-22; W-02, W-03, W-04, W-06, W-07,
   and W-10 generated classes extended to projection frames.
6. **Session replacement and bootstrap** in `crux_driver_serialized.ml`: the
   seven-step replacement sequence (preflight, fresh identity registration,
   bootstrap encode, old-session close, bootstrap send, permit settlement,
   result wait and fence lift), closed five-case preflight family,
   advancement fence, commit-with-no-session latch, loss-window recovery,
   terminal races, capacity and `Frame_too_large` bounds. The public
   `Serialized_session` signature and `replace_error` family are unchanged
   per [Session replacement and
   bootstrap](11-session-replacement-and-bootstrap.md). Gates: PRB-01 to
   PRB-19 (PRB-07 trimmed to the pending-delivery `Awaiting_delivery` clause;
   PRB-18 keeps only the push clause); the five `test_replace_error_*` gates
   and `test_session_replacement_permit_wait` close inherited gaps 2 and 3.
7. **Harness**: new `lib/crux_test/crux_projection_harness.ml` — delivery
   responder, write-failure injection, adapter-failure injection,
   codec-failure injection, replacement trigger, session-loss injection,
   incarnation-counter seed, capacity-pressure helpers.
   `crux_test_handle.ml` gains the test-only delivered-state shadow;
   `crux_recording_adapter.ml` records projection deliveries;
   `eta_crux_test.mli` is updated. Gates: H-09, H-10, H-11 (new); H-08
   amended.
8. **Conformance and races**: `conformance_projection_transport_equivalence`
   (new, shared; serves W-01 and H-11); `race_commit_atomicity`,
   `race_commit_vs_crash_both_winners`, `race_terminal_vs_delivery`,
   `race_pull_vs_commit_both_winners`, and `race_session_replacement` amended
   in place; `race_terminal_vs_bootstrap` and
   `race_replacement_vs_commit_both_winners` new. Every race gate controls both
   legal winners and finishes with an empty fiber census.
9. **Registry** (`docs/design/eta-crux-v1/semantic-laws.md`): add PRJ-01 to
   PRJ-30, PRW-01 to PRW-20 plus PRW-22, PRB-01 to PRB-19, and H-09 to H-11;
   amend T-03, T-04, D-02, D-03, D-07, D-08, D-09, O-01, O-02, F-04, F-05,
   W-01, W-02, W-03, W-04, W-06, W-07, W-08, W-10 ([Laws and deterministic test
   controls](12-laws-and-deterministic-test-controls.md)'s table) plus the
   vocabulary sweep C-05, T-02, GTC-14, GTC-18, RST-05, POLL-01, POLL-07,
   H-08. Renamed gates where the observation boundary changed:
   `qcheck_complete_output_per_commit` becomes
   `qcheck_projection_image_per_commit`; `qcheck_latest_committed_output`
   becomes `qcheck_latest_committed_snapshot`;
   `test_handle_output_boundaries` becomes `test_handle_projection_boundaries`.
   Amended gates with unchanged boundaries keep their names. PRW-21 and
   PRW-23 to PRW-29 are never written — the deletion is realized by omission,
   with [Select the public interface and
   seam](14-select-public-interface-and-seam.md) as the record. PRW-18 lands
   as a surviving row gated by the W-06 unknown-tag class plus the
   single-profile statement in `wire-protocol.md`. PRB-18 keeps exactly one
   surviving gate, `test_projection_bootstrap_frame_too_large`;
   `test_projection_bootstrap_paged` is deleted with the pull clause.
10. **Design documents**: `public-api.md` rewritten (Projection surface and
    Root/Driver/Adapter/Hosted signatures); `wire-protocol.md` rewritten
    (single profile, projection frames, output frames removed);
    `verification.md` updated (registered gates and suites); `README.md`
    overview updated. Glossary: `CONTEXT.md` already carries the projection
    entries from [Canonical domain language](07-canonical-domain-language.md)
    — verified for consistency, with no new entries. `crux_telemetry.ml` and
    `verification.md`'s fixed-name contract are checked for output-vocabulary
    attributes; any found are renamed in this change (the O-03 gate stays).
11. **Compile migration of remaining consumers**: `lib/crux_test`, all
    `test/crux/*` suites, and a minimal compile-only migration of
    `lib/crux/bench/bench_eta_crux.ml` (new workloads arrive in change 3).
    The negative suite is re-run against the new `.cmi`; no new negative
    cases (PRJ-15, PRJ-27, and PRJ-30 opacity is enforced by `.mli` absence).

Compile-time migrations in change 2: `Root.create` gains `catalog:` and
`projection_capacity:` and loses `'output`; the `'output` parameter is
removed from `Root.t`, `Driver.t`, `Driver.Binding.t`, `Driver.Delivery.t`,
`Adapter.resource`, `Adapter.delivery`, and `Hosted.run`;
`Binding.serialized` loses `output:` (codecs live in kinds);
`latest_committed_output` becomes `latest_committed_snapshot :
Projection.Snapshot.t option`; `Delivery.output` is replaced by exposure of
the typed `Projection.delivery`; `Root.outcome Committed` carries `commit :
Projection.Commit.t` instead of `output`.

Deletions in change 2: `Deliver_output` and `Output_result` frames, their
JSON and S-expression codecs, and their grammar classes (absorbed into the
extended W-02, W-03, W-06, W-07 projection classes); the `Output_delivery`
trigger; output-delivery workloads in `bench_eta_crux.ml`; every output-only
gate body per the amendment tables. No compatibility paths.

### Change 3 — performance gates

- `lib/crux/bench/bench_eta_crux.ml`: workloads
  `projection.no_change.{10000,100000}`,
  `projection.one_changed.{10000,100000}`,
  `projection.attach.{10000,100000}` (one population serves all three),
  `projection.bootstrap.{10000,100000}`, and `projection.absent`. New
  counters `batch_records`, `encoded_entries`, `encoded_bytes`,
  `cutoff_calls`, `key_compare_calls` (ceiling at most 8·N), and
  `bootstrap_entries`; `commits` and `deliveries` are unchanged.
- `bench/compare.ml`: `projection_absent_allocation` spec (equal word
  medians, wall within 5 percent, at least two of three pairs), the PRF-05
  cross-size ratio spec (100,000 at most twice the 10,000 median
  `allocated_words`), and `expected_crux_counters` entries for every exact
  counter.
- `[@zero_alloc]` sites: the pure projection helpers and the preflight
  validation walk in `crux_projection.ml` (PRF-03, PRF-08).
- Registry: PRF-01 to PRF-08 rows; PRF-06 keeps only the batch-push clause
  (one-changed `encoded_bytes` exactly equal at 10,000 and 100,000). The
  registered executable suite is `bench_eta_crux.exe` plus `compare.exe
  --gate`.
- The first full implementation run commits the budget baselines to
  `bench/results/`. Failure criteria per [Performance and zero-cost
  gates](13-performance-and-zero-cost-gates.md). `bench/run.sh` is
  unchanged.

### Gate schedule

Every surviving registry row with its exact named gate, by change item. Rows
whose gates are shared name the serving gate. Deleted rows and gates are
listed only in [Select the public interface and
seam](14-select-public-interface-and-seam.md).

**Change 1**

- R-10 — `test_requester_encode_failed`
- R-11 — `test_requester_decode_failed`
- R-12 — `test_responder_encode_failed`

**Change 2, item 2 — public `Projection` module**

- PRJ-01 — `qcheck_projection_publish_local_value`
- PRJ-02 — `test_projection_kind_generativity`
- PRJ-03 — `qcheck_projection_catalog_rejection`
- PRJ-04 — `test_projection_catalog_shared_roots`
- PRJ-05 — `test_projection_capacity_positive`
- PRJ-07 — `qcheck_projection_key_codec_laws`
- PRJ-08 — `qcheck_projection_value_codec_roundtrip`
- PRJ-09 — `qcheck_projection_key_compare_total_order`
- PRJ-15 — compile gate plus `test_projection_incarnation_opaque`
- PRJ-27 — `test_projection_typed_lookup_fold`
- PRJ-30 — compile gate (no production delivered-state query)

**Change 2, item 3 — commit machinery**

- PRJ-06 — `qcheck_projection_identity_equivalence`
- PRJ-10 — `qcheck_projection_identity_collision`
- PRJ-11 — `qcheck_projection_incarnation_continuity`
- PRJ-12 — shared with the PRJ-17 gate
- PRJ-13 — `qcheck_projection_incarnation_allocation`
- PRJ-14 — `test_projection_incarnation_exhausted`
- PRJ-16 — `qcheck_projection_cutoff_retention`
- PRJ-17 — `qcheck_projection_batch_validity`
- PRJ-18 — `qcheck_projection_cutoff_defect`
- PRJ-19 — `qcheck_projection_capacity_bounds`
- PRJ-20 — `test_projection_capacity_one_replacement` plus the PRJ-19 property
- PRJ-21 — `qcheck_projection_preflight_cause`
- PRJ-22 — shared with the PRJ-13 and PRJ-21 gates
- PRJ-24 — `qcheck_projection_commit_endpoints_only`
- PRJ-26 — `qcheck_projection_canonical_order`
- T-03 — `qcheck_projection_image_per_commit` (renamed from
  `qcheck_complete_output_per_commit`)

**Change 2, item 4 — driver delivery fences**

- PRJ-25 — `test_projection_initial_commit` plus
  `qcheck_projection_delivery_per_commit`
- PRJ-28 — `test_projection_delivered_shadow`
- PRJ-29 — `test_projection_install_before_ack`
- D-02 — `qcheck_delivery_token` (amended)
- D-07 — `qcheck_latest_committed_snapshot` (renamed from
  `qcheck_latest_committed_output`) plus
  `test_latest_committed_snapshot_retained_after_failed_delivery`,
  `test_latest_committed_snapshot_retained_after_stop`, and
  `test_latest_committed_snapshot_retained_after_crash` (new)
- D-09 — `test_pull_does_not_complete_delivery` (amended)
- O-01 — `test_snapshot_only_observation` (amended) plus the D-07 gates
- O-02 — `test_adapter_commit_boundary` (amended)
- F-05 — `test_adapter_delivery_failure` (amended)

**Change 2, item 5 — serialized binding**

- PRW-01 — `qcheck_projection_wire_entry_structure`
- PRW-02 — `qcheck_projection_wire_order_rejection`
- PRW-03 — `qcheck_projection_wire_count_exactness`
- PRW-04 — extends the W-06 and W-07 generated classes
- PRW-05 — extends the W-06 generated class
- PRW-06 — extends the W-03 generated class
- PRW-07 — `qcheck_projection_result_diagnostic`
- PRW-08 — `qcheck_projection_payload_rejection`
- PRW-09 — extends the W-04 generated class
- PRW-10 — `test_projection_push_frame_too_large` plus
  `qcheck_projection_frame_size_boundary`
- PRW-11 — `qcheck_projection_wire_key_canonicality`
- PRW-12 — `test_projection_encode_failure_key` and
  `test_projection_encode_failure_value`
- PRW-13 — `test_projection_codec_raise_defect`
- PRW-14 — extends the W-10 generated class
- PRW-15 — `qcheck_projection_shell_transition_validation`
- PRW-16 — `test_projection_adapter_atomic_install`
- PRW-17 — shared with the W-06 gate
- PRW-18 — W-06 unknown-tag class plus the single-profile statement in
  `wire-protocol.md`
- PRW-19 — `test_projection_value_handle_fence`
- PRW-20 — `test_projection_identity_zero_codec`
- PRW-22 — `qcheck_projection_bp_reason_content_pairing`
- W-02 — `qcheck_wire_sequence` (generated class extended to projection
  frames)
- W-03 — `qcheck_wire_reply_correlation` (extended)
- W-04 — `qcheck_malformed_frame_isolation` (extended)
- W-06 — `qcheck_exact_envelope_grammars` (extended)
- W-07 — `qcheck_wire_bounds` (extended)
- W-10 — `qcheck_wire_redaction` (extended)

**Change 2, item 6 — session replacement and bootstrap**

- PRB-01 — `test_projection_bootstrap_source`
- PRB-02 — `test_projection_bootstrap_incarnation_continuity`
- PRB-03 — `test_projection_bootstrap_atomic_install`
- PRB-04 — `test_projection_replacement_step_order`
- PRB-05 — `test_projection_bootstrap_first_delivery`
- PRB-06 — `test_replace_error_starting`,
  `test_replace_error_replacement_pending`,
  `test_replace_error_awaiting_delivery`, `test_replace_error_terminating`,
  and `test_replace_error_closed`
- PRB-07 — shared with `test_replace_error_awaiting_delivery`
- PRB-08 — shared with `test_replace_error_closed`
- PRB-09 — `test_projection_replace_empty_bootstrap`
- PRB-10 — `test_projection_commit_no_session`
- PRB-11 — `test_projection_replace_in_loss_window`
- PRB-12 — `test_projection_bootstrap_no_post_commit`
- PRB-13 — `test_projection_bootstrap_failure_crashes` and
  `test_projection_bootstrap_session_loss`
- PRB-16 — `test_projection_advancement_fence`
- PRB-17 — shared with the PRJ-19 gate
- PRB-18 — `test_projection_bootstrap_frame_too_large`
- PRB-19 — `test_projection_initial_attach_no_bootstrap`
- W-08 — `test_session_replacement_permit_wait` (new) plus
  `race_session_replacement` (item 8)

**Change 2, item 7 — harness**

- H-09 — `test_projection_responder_one_answer`
- H-10 — `test_projection_held_delivery_fences_post_commit`
- H-11 — shared with the conformance gate
- H-08 — `test_handle_projection_boundaries` (renamed from
  `test_handle_output_boundaries`)

**Change 2, item 8 — conformance and races**

- W-01 — `conformance_projection_transport_equivalence` (new, shared; also
  serves H-11)
- T-04 and PRJ-23 — `race_commit_atomicity` (amended)
- F-04 — `race_commit_vs_crash_both_winners` (amended)
- D-03 — `race_terminal_vs_delivery` (amended) and
  `race_terminal_vs_bootstrap` (new)
- PRB-14 — `race_terminal_vs_bootstrap` (new)
- D-08 — `race_pull_vs_commit_both_winners` (amended)
- W-08 — `race_session_replacement` (amended)
- PRB-15 — `race_replacement_vs_commit_both_winners` (new)

**Change 3 — performance gates**

- PRF-01 — `bench_projection_no_change`
- PRF-02 — `bench_projection_no_change` and `bench_projection_one_changed`
- PRF-03 — `bench_projection_no_change` ceiling plus the `[@zero_alloc]`
  compile gate on the preflight validation walk
- PRF-04 — `bench_projection_one_changed` and `bench_projection_attach`
- PRF-05 — `compare.exe` cross-size ratio spec
- PRF-06 — `bench_projection_one_changed` (batch-push clause)
- PRF-07 — `bench_projection_bootstrap`
- PRF-08 — `compare.exe` `projection_absent_allocation` spec plus the
  `[@zero_alloc]` helpers

**Change 2, item 9 — vocabulary-only amendments**

These rows keep their gates unchanged; only the prose is amended.

- C-05 — `qcheck_cutoff_boundary`
- T-02 — `test_idle_is_inert`
- GTC-14 — `qcheck_graph_time_commit_fence`
- GTC-18 — `qcheck_graph_time_transport_equivalence`
- RST-05 — `qcheck_reset_ingress_order`
- POLL-01 — `qcheck_poll_starting_incarnation`
- POLL-07 — `qcheck_poll_committed_run_order`

### Affected packages

`eta_crux` (as above), `eta_crux_json`, `eta_crux_sexp` (protocol codecs
plus vendored wire-common), `eta_crux_test`,
`test/crux/{laws,unit,races,conformance,wire,telemetry,negative}`, and
`bench`. The root `eta` package is untouched. No `drivers/` package consumes
`eta_crux`.

[Design package coherence audit](16-design-package-coherence-audit.md)
resolved this plan with corrections. [Exact projection read and delivery
signatures](18-exact-projection-read-and-delivery-signatures.md) supplies the
exact signatures that item 2 delegates, and it blocks [Design package
approval](17-design-package-approval.md).
