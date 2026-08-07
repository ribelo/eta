# Eta Signal execution-model map

## Destination

An implementation-ready replacement architecture and pre-alpha implementation
for `eta_signal` and `eta_signal_map`. The implementation must preserve the
Signal behavior contract and meet workload-specific performance gates.

## Notes

Planning and throwaway prototypes selected the pre-alpha base through issue 11.
Issue 17 promotes that base into the production packages.
Later tickets change the production pre-alpha implementation directly.

Executable semantics and public behavior remain binding. All internal
architecture decisions reopen. The prior Signal Wayfinder work and current
engine are evidence, not design templates.

A pure graph kernel is the primary hypothesis. Only an executable semantic
counterexample can reject this hypothesis. One kernel can activate structural,
rollback, timer, or delivery machinery only when the current pass requires it.

Incremental is the zero-effect performance reference, not a compatibility
target. Comparisons must have three layers:

1. Compare the raw Eta kernel with the matched Incremental kernel.
2. Measure each Eta adapter around the same raw Eta kernel.
3. Compare complete public operations with matched workloads.

Affected-work complexity and correctness are eligibility gates. Rank eligible
candidates by module depth, allocation, and wall time. Use workload-specific
targets from the best relevant reference. Static scalar stabilization must
allocate fewer than 100 words, independent of graph depth.

The preferred result retains the public Signal interface. The effort can change
that interface when another design creates a substantially deeper module. It
must not add a compatibility path.

The scope includes Eta core changes that Signal needs, `eta_signal`, and
`eta_signal_map`. A small general Eta runtime primitive is allowed when Signal
provides its motivating invariant. Time, churn, and migration effort are not
constraints.

Use `$simple-english` for written artifacts. Use `$codebase-design` and its
Design It Twice method for module interfaces. Use `$prototype` for prototype
tickets, `$research` for external source work, and `$domain-modeling` when the
Signal language changes.

Use the OxCaml toolchain. Keep frozen benchmark workloads and formulas
unchanged. Keep durable research under
`.scratch/research/eta-signal-execution-model/`. Keep throwaway code outside the
main Dune workspace.

## Decisions so far

- [Binding Signal behavior](issues/01-binding-signal-behavior.md) — preserve 32 public observation rows while reopening every private execution representation.
- [Incremental layered baseline](issues/02-incremental-layered-baseline.md) — use the zero-allocation raw static core and measure each adapter as a separate baseline layer.
- [Eta execution-cost decomposition](issues/03-eta-cost-decomposition.md) — reject the current `729 + 68d`-word raw planner and keep Effect, lane, runtime, observer, and timer costs separate.
- [Performance acceptance matrix](issues/04-performance-acceptance-matrix.md) — require behavior and affected-work eligibility, layered allocation ceilings, and fresh paired wall-time comparisons before ranking eligible candidates.
- [Candidate kernel seams](issues/05-candidate-kernel-seams.md) — use direct synchronous propagation as the primary hypothesis, falsify immutable plans with a static probe, and defer the private claim versus edge-cursor seam to adapter prototypes.
- [Value-propagation kernel](issues/06-value-propagation-kernel.md) — retain direct propagation after it passes all static gates at 4 words per operation, and reject depth-dependent immutable snapshots.
- [Failure and rollback model](issues/07-failure-and-rollback-model.md) — use a sparse undo journal of node indices with an O(1) commit, and falsify lazy epoch rollback with a cutoff counterexample.
- [Dynamic topology and keyed work](issues/08-dynamic-topology-and-keyed-work.md) — use owner-local shadow capsules with an O(1) verdict commit and affected-only rollback and cleanup.
- [Node identity and index lifecycle](issues/15-node-identity-and-index-lifecycle.md) — reuse dense slots with generation-safe handles and per-pass quarantine, while active journals retain immediate slot integers.
- [Generic typed value storage](issues/16-generic-typed-value-storage.md) — pack existential typed nodes with embedded undo values, preserve the four-word path for immediate and boxed values, and reject erased or closure-packed storage.
- [Effect seam and Eta runtime](issues/09-effect-seam-and-runtime.md) — use one private serialized execution driver with a pre-publication cancellation checkpoint, keep claims opaque, and add no Eta runtime primitive.
- [Timer and observer edges](issues/10-timer-and-observer-edges.md) — keep timer generations, runtime provenance, observer cursors, cleanup, and stream acknowledgement inside one opaque post-commit driver.
- [Integrated finalist proof](issues/11-integrated-finalist-proof.md) — reject the behavior-complete finalist for final selection, then retain it as the production pre-alpha base.
- [Promote selected finalist to pre-alpha](issues/17-promote-selected-finalist-to-pre-alpha.md) — replace production kernel with selected core, edge driver, and factory, wire Eta_signal, Eta_signal_map, and Eta_signal_stream, delete old engine modules and representation tests, keep scratch as evidence.

## Current path

1. Decide the [public interface and graph ownership](issues/12-public-interface-depth.md) on the promoted code.
3. Decide [module and package ownership](issues/13-module-and-package-ownership.md) and move the production code.
4. Write the [consolidated execution specification](issues/14-consolidated-execution-specification.md) after all gates pass.

## Not yet specified

- Additional workload classes can become necessary when the behavior census
  finds a capability without a matched benchmark.

## Out of scope

- Eta Crux, including changes made only for its use of Signal.
- Eta packages unrelated to the selected Signal execution model.
- Compatibility with the Incremental interface.
- Compatibility shims for the current Signal implementation.
- Changes to frozen benchmark workloads, checks, operation counts, or formulas.
