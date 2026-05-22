# Portable islands use-case checks

Date: 2026-05-22

## H4-H6 Boundary Scope

The reduced invariant checklist is recorded in invariants.md.

Status:

- H4 reduced invariant checklist holds for the first useful island prototype.
- H5 explicit API holds: the boundary is named Island, not hidden behind
  existing Effect.all.
- H6 batch-only holds: islands cover finite batches; stream/exporter transport
  remains out of scope.

## H7 Cancellation / Timeout

Status: v1 should not expose timeout.

busy_loop_not_preempted.ml compiles but is not run. This is intentional:
arbitrary CPU callbacks cannot be preempted safely. Island v1 should document
finite jobs only. A future cooperative timeout would need an explicit polling
token, but the first useful island prototype does not need it.

## H9 Ergonomics

ergonomics_examples.ml compiled and ran:

    ergonomics examples=true annotations=3 ppx_required=false

The examples cover:

- parse over bytes;
- validate over JSON-like strings with typed errors;
- encode values.

Manual @ portable annotations are visible but not enough to require PPX for v1.
