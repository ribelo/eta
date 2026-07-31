# State representation seam and plain-state V1

Type: grilling
Status: open

## Question

V1 must be an eta_crux with **no `eta_signal` as state**, planned at such an angle that an
`eta_signal` graph backend can be added later without redesign. Decide the seam, and decide
plain-state semantics.

Sorting the current 179 requirements by what they actually depend on gives the seam:

- **Backend-agnostic**: action queue and admission, per-cell FIFO, commands, slots and
  command concurrency, defects and crash reporting, the boundary contract and capability
  messages, driver operations, and most of the test harness.
- **Backend-specific**: model storage, output derivation and cutoff, structure
  reconciliation, and scope lifecycle. That is `engine-strategy` entirely, the settle phase
  of `tick`, `bind` and `assoc` in `composition`, and parts of `core-loop`, `fragments` and
  `lifecycle`.

So a backend supplies model storage and read, output derivation, structure reconciliation
with scope lifecycle, and a settle step — stabilization for the graph, and nothing for
plain.

To decide:

- What the plain backend stores, and how outputs are derived from it. Declared equality at
  the exposure boundary is already required, so plain can recompute outputs per tick and
  diff by that same equality instead of relying on graph cutoffs — one contract, two
  mechanisms.
- Whether plain supports dynamic *cell* structure at all, or is static-structure-only with
  collections held as data, in the Elm and Foldkit shape, while dynamic cells remain a
  graph-backend capability. Parity means a second reconciliation-and-scope implementation,
  which is the most expensive and least testable part.
- Which requirements become backend-conditional, and how the notes express that without
  forking into two parallel bundles.
- What the graph backend adds later, stated precisely enough that adding it is additive
  rather than a rewrite.

Consequences to confirm: under plain-state V1 both the `eta_signal_map` hook and the
input-dependent-cell settle question leave V1's critical path.
