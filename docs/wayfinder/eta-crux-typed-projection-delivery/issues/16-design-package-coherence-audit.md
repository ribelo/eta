# Design package coherence audit

Type: task
Status: resolved
Blocked by: 15

## Question

Does the complete package meet every destination criterion without
contradiction?

Check citations, terminology, public types, laws, wire contracts, identity
equivalence, session replacement, capacity outcomes, test controls, performance
gates, and the implementation plan.

Make sure that one commit maps to one coherent adapter observation. Make sure
that applications own no replay or resynchronization protocol.

## Answer

The reviewed decisions are mutually coherent after nine record corrections,
and every checked source claim matches current code. One destination criterion
remains open: the exact public signatures graduate to [Exact projection read
and delivery
signatures](18-exact-projection-read-and-delivery-signatures.md), which blocks
[Design package approval](17-design-package-approval.md). No contradiction
survives.

A high-tier audit agent checked every resolved ticket against the others and
every source claim against current code. The parent verified each finding
against the cited spans before applying a correction.

### Corrections applied

1. [Session replacement and
   bootstrap](11-session-replacement-and-bootstrap.md): the preflight family
   now states the general rule. Any unacknowledged delivery blocks replacement
   with `Awaiting_delivery`. The pull-notification case is one instance. The
   current driver already maps `Delivering` and `Replacement_delivering` to
   `Awaiting_delivery` (`lib/crux/crux_driver.ml:258-260`).
2. [Laws and deterministic test
   controls](12-laws-and-deterministic-test-controls.md) PRB-07: restated as
   the general rule plus a pull-only frozen-observation clause. The trim that
   [Select the public interface and
   seam](14-select-public-interface-and-seam.md) performs now leaves a real
   clause.
3. [Laws and deterministic test
   controls](12-laws-and-deterministic-test-controls.md) PRW-15: `count and
   continuation` split. `count` stays common. `continuation` becomes an
   explicit pull-only clause that the selection change deletes.
4. [Laws and deterministic test
   controls](12-laws-and-deterministic-test-controls.md) PRW-10: the boundary
   property is now named `qcheck_projection_frame_size_boundary`. Every law
   has a named gate.
5. [Laws and deterministic test
   controls](12-laws-and-deterministic-test-controls.md) PRW-16: binding tag
   changed to `both`. Adapter atomic installation is binding-independent, and
   the harness adapter-failure injection works on both bindings. The identity
   binding now has a gate for host-visible atomic install. PRB-18 also marks
   which gate belongs to each profile.
6. [Performance and zero-cost
   gates](13-performance-and-zero-cost-gates.md) PRF-07: `deliveries=1` now
   counts one answered delivery, so the single acknowledgment is observed.
   D-02 and H-09 gate the one-answer property itself.
7. [Select the public interface and
   seam](14-select-public-interface-and-seam.md): the deletion list now names
   the exact shared-row clauses and the `test_projection_bootstrap_paged`
   gate.
8. [Implementation plan](15-implementation-plan.md): adds W-04 and W-10
   generated-class extensions, adds the amended `race_session_replacement`
   gate, names the surviving PRB-18 gate, and gains a gate schedule that maps
   every surviving registry row to its exact gate name.
9. [Identity, codec, and wire
   contract](10-identity-codec-and-wire-contract.md): adapter atomicity now
   says "complete new delivered projection snapshot". This matches the
   canonical per-identity meaning of projection state.

### Graduated gap

Neither [Alternative public interfaces](08-alternative-public-interfaces.md)
nor [Identity, codec, and wire contract](10-identity-codec-and-wire-contract.md)
pins the exact signatures of `Snapshot`, `Batch`, `Commit`, the update type,
typed lookup, the existential fold, or the changed `advance`, delivery,
adapter, and hosted signatures. [Select the public interface and
seam](14-select-public-interface-and-seam.md) overstates the standing surface.
This gap is a decision for the user, so it graduates to [Exact projection read
and delivery signatures](18-exact-projection-read-and-delivery-signatures.md).
[Design package approval](17-design-package-approval.md) is now blocked by
that ticket.

### Refuted suspicion

`Output_deliver` versus `Deliver_output` is not an error. The public
`Wire.Frame.t` constructor is `Output_deliver` (`lib/crux/eta_crux.mli:477`).
The internal protocol-model constructor is `Deliver_output`
(`lib/crux_wire_common/protocol_model.ml:58`). Each ticket names its own
layer.

### Source fidelity

Every checked source claim matches current code. This includes
`Driver.latest_committed_output`, the five `replace_error` cases, the
`Adapter_delivery` latch, acknowledgment-gated post-commit work, byte 11 for
`Output_delivery`, all referenced registry rows, all ten named existing test
gates, the bench counter and `Counting_format` patterns, the `compare.exe
--gate` regression rules, `Cutoff.t`, the export-handle fence names, the
projection glossary in `CONTEXT.md`, and the baseline research report.

### Contract checks

One commit maps to one coherent adapter observation. The commit owns one
snapshot and one batch. The recipient installs the complete new delivered
snapshot before it acknowledges. The PRW-16 retag extends this gate to the
identity binding.

Applications own no replay or resynchronization protocol. Replacement
redelivers the driver-retained committed snapshot. PRB-01 prohibits
application replay.

[Exact projection read and delivery
signatures](18-exact-projection-read-and-delivery-signatures.md) is new. No
other ticket is necessary.
