# Eta Crux typed projection delivery map

## Destination

An approved Eta Crux design package for typed projection delivery. The package
defines the public interface, semantic contracts, executable gates, and an
implementation plan.

## Notes

Planning is the deliverable. Do not implement the capability before the user
approves the design.

The design must preserve the Eta Crux ownership seam. Eta Crux owns
stabilization, atomic commit, delivery order, serialized sessions, and delivery
acknowledgment. The driver remains the only transport writer.

Do not assume that changed-projection delivery is the correct design. Compare it
with complete-output delivery, notification followed by pull, independent
streams, and application effects.

Use primary sources and current source code. Reuse the existing capability
audit, but make sure that important claims still match current sources.

Save durable research in
`.scratch/research/eta-crux-typed-projection-delivery/`.

Use the research, codebase-design, domain-modeling, and simple-english skills.
Use Design It Twice for alternative public interfaces after research and
terminology decisions unblock that work.

Every accepted law needs a named executable gate and an exact observation
boundary. Generated gates must identify their generated class. Race gates must
control both legal winners where both outcomes are valid.

The final package must name identity and serialized transport observations,
session replacement, deterministic controls, capacity outcomes, performance
gates, and all affected Eta packages and modules.

## Decisions so far

<!-- Closed tickets are indexed here. Each decision remains in its ticket. -->

- [Current Eta Crux delivery baseline](issues/01-current-eta-crux-delivery-baseline.md)
  — Current Eta Crux delivers complete committed outputs. The baseline corrects
  stale pull, clock, and session claims and records three gate gaps.
- [Incremental and Bonsai publication semantics](issues/02-incremental-and-bonsai-publication-semantics.md)
  — Incremental and Bonsai support stabilize-then-publish, bounded notification
  frequency, explicit disposal, internal cutoff, and latest-value pull patterns.
- [StateFlow publication semantics](issues/03-stateflow-publication-semantics.md)
  — StateFlow supports one retained current value, equality conflation, and
  current-value replay, but not atomic multi-flow observation or acknowledgment.
- [Rust Crux and Elm publication semantics](issues/04-rust-crux-and-elm-publication-semantics.md)
  — Rust Crux supports notification-then-pull, while Elm publishes one
  frame-coalesced whole-program view. Neither defines typed projection delivery.
- [Snapshot-subscription and incremental-view prior art](issues/05-snapshot-subscription-and-incremental-view-prior-art.md)
  — React supplies a missed-wake fence. Solid, Feldera, and Materialize add
  batching and snapshot patterns, but none meets Eta Crux acknowledgment and
  ownership contracts.
- [Prior-art transfer matrix](issues/06-prior-art-transfer-matrix.md)
  — Prior art supplies separate patterns for commit-fenced publication,
  current-snapshot notice and pull, and bounded consumption. No source replaces
  Eta Crux acknowledgment, ordering, session, capacity, or ownership contracts.
- [Canonical domain language](issues/07-canonical-domain-language.md)
  — Projection is canonical. Its vocabulary separates values, identities,
  incarnations, updates, batches, states, transport handles, and bootstrap.
- [Alternative public interfaces](issues/08-alternative-public-interfaces.md)
  — Three interfaces are eligible. Changed complete-value batch push is
  recommended. Independent streams and application publication conflict with
  Eta Crux delivery semantics.
- [Commit observation and ownership contract](issues/09-commit-observation-and-ownership-contract.md)
  — Each commit owns one atomic snapshot and batch. The driver retains committed
  state, recipients retain delivered state, and acknowledgment gates post-commit
  work.

## Not yet specified

- The internal module split and migration sequence depend on the selected public
  interface and transport contract.
- The final approval changes can only be specified after the package coherence
  audit.

## Out of scope

- Capability implementation before design approval.
- Application-specific projection values or rendering policy.
- Application-owned replay, revision, or resynchronization protocols.
- A compatibility shim for an earlier Eta Crux interface.
- Transport writers outside the driver.
