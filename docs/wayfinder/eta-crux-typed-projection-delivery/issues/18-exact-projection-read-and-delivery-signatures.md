# Exact projection read and delivery signatures

Type: grilling
Status: open
Blocked by: 16

## Question

What are the exact public OCaml signatures for the projection read and
delivery surface?

The selected interface names these types but does not pin their signatures:

- `Projection.Snapshot.t`, `Projection.Batch.t`, and `Projection.Commit.t`
  with their accessors. [Alternative public
  interfaces](08-alternative-public-interfaces.md) says the public commit
  interface exposes the batch and the snapshot. State the exact accessors.
- The public update type. Typed batch lookup by kind and key returns the
  ordered update list for one identity. State how an update carries the typed
  key, incarnation, and value for one `('key, 'value) Kind.t`.
- The rank-2 existential fold over snapshots and batches. State its exact
  form, for example an existential entry wrapper or a record of polymorphic
  functions. Compare the alternatives with Design It Twice.
- The `Root.advance` result type with `Projection.Commit.t`.
- The `Driver.Delivery.t` exposure of the typed `Projection.delivery`, the
  `Adapter.delivery` signature without `'output`, and the `Hosted.run`
  signature without `'output`.
- The public `Wire.Frame.t` projection variants in `eta_crux.mli`. The
  semantic frame data and grammars in [Identity, codec, and wire
  contract](10-identity-codec-and-wire-contract.md) already fix their
  content.

Every signature must preserve the opacity rules. Snapshots, batches, commits,
and incarnations stay opaque. No production query exposes delivered state.
