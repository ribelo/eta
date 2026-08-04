# Final design and legacy reconciliation

Type: task
Status: resolved
Blocked by: 15, 20, 21

## Question

Replace the provisional Eta Crux requirement and design bundle with one
implementation-ready V1 design that reflects every resolved decision in this
map.

The work must:

- define the final document set and its authority.
- remove or rewrite stale requirements, concepts, and ADRs.
- preserve useful provenance through links to resolved tickets and tracked
  research.
- contain the complete public API and package boundaries.
- state every lifecycle, ordering, failure, transport, and testing law once.
- identify the executable test or planned implementation gate for each law.
- leave no provisional path that contradicts the final design.

This task changes design documentation only. It does not implement Eta Crux.

## Answer

The authoritative V1 design is
[`docs/design/eta-crux-v1/`](../../../design/eta-crux-v1/README.md).
It contains four linked contracts:

- the package and architecture index.
- the complete public OCaml API.
- the exact serialized wire protocol.
- one semantic-law registry with one named implementation gate for each law.
- the public test surface, telemetry contract, and performance gates.

The old `docs/requirements/eta-crux/` bundle and
`docs/wayfinder/eta-crux/` map were removed. They described the superseded
command, subscription, fragment, output-tree, and backend designs.

`CONTEXT.md` now removes those stale terms. It defines `Source` and `Root output`
for the final design.

The first-principles map and its resolved tickets remain as design provenance.
They are not a second contract. Eta Signal and Eta supervision keep their own
authoritative package contracts.
