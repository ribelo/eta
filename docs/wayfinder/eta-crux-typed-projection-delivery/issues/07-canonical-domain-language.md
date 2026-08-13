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
- **Projection identity**: the stable name of one logical projection. The name
  remains stable during one projection incarnation.
- **Projection incarnation**: one continuous active lifetime of one projection
  identity.
- **Projection attachment**: the association between an active incarnation and
  its current projection value.
- **Projection update**: one `Attached`, `Changed`, or `Removed` member of a
  projection batch.
- **Projection batch**: one atomic set of projection updates from one successful
  commit. The batch can be empty.
- **Projection state**: `Active` with an incarnation and projection value, or
  `Absent`.
- **Latest committed projection state**: the projection state after the latest
  completed commit.
- **Latest delivered projection state**: the projection state after the latest
  projection batch whose delivery the host accepted.
- **Changed projection value**: the complete new value in a `Changed` update.
  It is not a diff.
- **Projection removal**: a `Removed` update that ends the active incarnation
  and makes its projection state `Absent`.
- **Projection handle**: an opaque transport handle that represents a
  projection during one serialized shell session.
- **Projection bootstrap**: the process that gives a serialized shell session
  its starting projection states.
- **Bootstrap batch**: an atomic batch that carries those starting states.

`Attached` starts an incarnation and carries its first projection value.
`Changed` carries a complete new value for the same incarnation. `Removed`
records explicit removal.

The matching definitions are now in
[`CONTEXT.md`](../../../../CONTEXT.md#projection). Identity continuity across
removal belongs to [Identity, codec, and wire
contract](10-identity-codec-and-wire-contract.md). Cutoff and commit delivery
semantics belong to [Commit observation and ownership
contract](09-commit-observation-and-ownership-contract.md). Projection bootstrap
ordering belongs to [Session replacement and
bootstrap](11-session-replacement-and-bootstrap.md).

No new ticket is necessary.
