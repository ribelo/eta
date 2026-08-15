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
   PRJ-27, PRJ-30 (compile).
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
   updated. Gates: PRW-01 to PRW-20 and PRW-22; W-02, W-03, W-06, and W-07
   generated classes extended to projection frames.
6. **Session replacement and bootstrap** in `crux_driver_serialized.ml`: the
   seven-step replacement sequence, closed five-case preflight family,
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
   `race_commit_vs_crash_both_winners`, `race_terminal_vs_delivery`, and
   `race_pull_vs_commit_both_winners` amended in place;
   `race_replacement_vs_commit_both_winners` new. Every race gate controls
   both legal winners and finishes with an empty fiber census.
9. **Registry** (`docs/design/eta-crux-v1/semantic-laws.md`): add PRJ-01 to
   PRJ-30, PRW-01 to PRW-20 plus PRW-22, PRB-01 to PRB-19, and H-09 to H-11;
   amend T-03, T-04, D-02, D-03, D-07, D-08, D-09, O-01, O-02, F-04, F-05,
   W-01, W-02, W-03, W-06, W-07, W-08 ([Laws and deterministic test
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
   single-profile statement in `wire-protocol.md`.
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

### Affected packages

`eta_crux` (as above), `eta_crux_json`, `eta_crux_sexp` (protocol codecs
plus vendored wire-common), `eta_crux_test`,
`test/crux/{laws,unit,races,conformance,wire,telemetry,negative}`, and
`bench`. The root `eta` package is untouched. No `drivers/` package consumes
`eta_crux`.

[Design package coherence audit](16-design-package-coherence-audit.md) is
unblocked. No new ticket is necessary.
