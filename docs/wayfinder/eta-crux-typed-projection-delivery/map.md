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
