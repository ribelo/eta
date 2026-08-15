# Integrated design and handoff

Type: grilling
Status: resolved
Blocked by: 19, 20, 21

## Question

Does the complete decision set form one coherent, implementation-ready Eta
component design?

Reconcile the public interfaces, lifecycle, context, coeffects, runtime seam,
desired-state loader, HMR contract, package ownership, laws, and performance
gates. Resolve contradictions without adding compatibility paths or silent
defaults.

Produce the implementation sequence and final verification matrix. The map is
complete only after the user approves this handoff.

## Answer

The user approved all ten integration choices from the coherence review:

- closed `Activation.own` admission is requested lifecycle interruption.
- release-error rendering is explicit and preserves the authoritative cause.
- provider-episode equality uses one opaque identity.
- interception uses an ordered monoid fold without universal right bias.
- desired-state reconciliation is the only instance-creation authority.
- cleanup failure has operation-specific terminal behavior.
- replacement admission checks an accepted target revision.
- callback exceptions follow their execution boundary.
- `Component.make` rejects duplicate and self-dependent schema keys.
- conflicting targets use latest-accepted supersession and one shutdown fence.

The complete proposed contract, package interfaces, implementation sequence,
and verification matrix are in the
[integrated handoff](../assets/integrated-handoff.md).

The user approved the complete handoff. The decision set now forms one
coherent, implementation-ready Eta component design.
