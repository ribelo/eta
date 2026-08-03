---
kind: requirement
tags: [eta_crux, fragments, eta_signal, derived-state]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/core-loop]]"]
traces_to: ["[[docs/prds/0002-eta-signal-frp]]"]
---
# Output fragment derivation

## Intent

Eta Crux exposes optional output fragments. A fragment is a typed value derived
from a cell model or other computation values and exposed at an address in the
application's output tree. Cells without output expose no fragments.

Fragments are not a universal dynamic output variant. A scalar fragment is a
typed derived value. A collection fragment is a keyed collection. An adapter that
needs one aggregate value derives that value by folding the exposed fragments at
the adapter boundary.

Fragment addresses mirror graph structure. Address segments are static labels or
data keys. Eta Crux reconciles fragment nodes by address and type, so stateful
adapters can retain toolkit objects while the corresponding fragment address
remains live.

Exposed fragment equality is declared at the exposure boundary. Primitive
fragment constructors provide equality. Custom scalar fragments require an
`equal` function. Collection fragments require key identity and per-row equality.

Eta Crux supports pull observation of the current stabilized output tree and
push observation of changed fragments or subtree changes.

## Requirements

- When application code exposes a fragment from a cell, eta_crux shall require the
  fragment to be derived by a pure projection from that cell's model or from
  other computation values available to that cell. ^vm-h7k2
- When application code exposes a pure fragment projection, eta_crux shall lift
  that projection into the computation graph. ^vm-n5r8
- When application code composes fragments at the computation-value level,
  eta_crux shall support composition through graph transformations. ^vm-c4p9
- When a cell exposes output fragments, eta_crux shall derive those fragments as
  computation values and shall leave aggregation into a single adapter value to
  the adapter. ^vm-4c9d
- Where fragments are exposed, eta_crux shall expose typed values rather than a
  universal dynamic output variant. ^vm-k2p7
- When application code exposes a fragment, eta_crux shall require
  exposed-fragment equality to be declared at the exposure boundary. ^vm-s7h4
- Where fragments are exposed, eta_crux shall expose them as a path-addressed
  tree. ^vm-7k3p
- When eta_crux assigns a fragment address, eta_crux shall build the address from
  static-label segments and data-key segments. ^vm-2m9x
- When eta_crux reconciles fragment nodes across stabilizations, eta_crux shall
  reconcile them by address and fragment type. ^vm-4h8w
- While a fragment node's address and type remain live after stabilization,
  eta_crux shall retain that fragment node; when the address or type is no
  longer live, eta_crux shall dispose that fragment node. ^vm-9c1r
- When an observer pulls application output, eta_crux shall return the current
  stabilized fragment tree without triggering graph mutation. ^vm-b3n8
- When an exposed fragment changes after stabilization, eta_crux shall
  notify registered push observers with the fragment address and
  changed value. ^vm-6w1q
- When graph stabilization adds or removes an exposed fragment subtree, eta_crux
  shall notify registered push observers with the subtree address and change
  kind. ^vm-b2n7
- While an exposed fragment's equality check reports no change after
  stabilization, eta_crux shall not notify push observers for that
  fragment. ^vm-e5c2

## Open questions

- Exact fragment constructor API for scalar fragments, collection fragments, and
  addressed subtree composition.
- Whether fragment addresses are exposed as typed paths, opaque handles, or both.
