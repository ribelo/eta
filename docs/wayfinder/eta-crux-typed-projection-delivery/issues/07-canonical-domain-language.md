# Canonical domain language

Type: grilling
Status: resolved
Blocked by: 06

## Question

What terms precisely describe the capability?

Choose whether `projection`, `observation`, or another term is canonical.
Sharpen the terms for one typed complete derived value, its stable identity, one
commit batch, attachment state, and explicit removal.

Define related terms for active lifetime, changed value, committed state,
delivered state, transport handle, and session bootstrap. Update `CONTEXT.md`
only after the terms are resolved.

## Answer

`Projection` is the canonical term. It names a structural computation
occurrence that produces one typed, complete derived value. `Observation`
remains a general act or record. `Publication` names a commit action, and
`delivery` includes transport acknowledgment.

The resolved terms are:

- **Projection value**: the complete typed value from one projection for one
  committed graph state.
- **Projection kind**: one generative immutable descriptor for keyed projection
  values.
- **Projection catalog**: the closed ordered set of projection kinds for one
  root contract.
- **Projection identity**: one projection kind and one equivalent key. The
  identity can have several incarnations over time.
- **Projection incarnation**: one continuous active lifetime of one projection
  identity.
- **Projection attachment**: the association between an active incarnation and
  its current projection value.
- **Projection update**: one `Attached`, `Changed`, or `Removed` member of a
  projection batch.
- **Projection batch**: one atomic ordered sequence of projection updates from
  one successful commit. The batch can be empty.
- **Projection image**: the complete framework-owned outward state from one
  successful commit. It contains all active projection attachments.
- **Projection state**: `Active` with an incarnation and projection value, or
  `Absent`.
- **Latest committed projection state**: the projection state after the latest
  completed commit.
- **Latest delivered projection state**: the projection state after the latest
  projection delivery that the host accepted.
- **Changed projection value**: the complete new value in a `Changed` update.
  It is not a diff.
- **Projection removal**: a `Removed` update that ends the active incarnation
  and makes its projection state `Absent`.
- **Projection bootstrap**: the process that gives a serialized shell session
  its starting projection states.
- **Bootstrap snapshot**: an atomic snapshot that carries those starting states.

`Attached` starts an incarnation and carries its first projection value.
`Changed` carries a complete new value for the same incarnation. `Removed`
records explicit removal.

The matching definitions are now in
[`CONTEXT.md`](../../../../CONTEXT.md#projection). Identity continuity across
removal belongs to [Identity, codec, and wire
contract](10-identity-codec-and-wire-contract.md). That contract also rules out
projection remote handles. Cutoff and commit delivery semantics belong to
[Commit observation and ownership
contract](09-commit-observation-and-ownership-contract.md). Projection bootstrap
ordering belongs to [Session replacement and
bootstrap](11-session-replacement-and-bootstrap.md).

No new ticket is necessary.
