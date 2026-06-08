# Prior art and references for caqti-eio fit investigation

To be filled by CQ-1 (API audit). Placeholder for the experimenter.

## What CQ-1 produces here

- caqti-eio package shape: how it differs from caqti-lwt / caqti-async
- `Caqti_eio.connect` signature, expected `Switch.t` / `Eio.Stdenv.t` plumbing
- `Caqti_eio.CONNECTION` first-class module surface
- `Caqti_eio.Pool` semantics: bounded? FIFO? health hook? eviction?
- `Caqti_request.t` shape: how typed-statement caching works
- `Caqti_type.t` shape: codec story, custom types, arrays, JSON
- `Caqti_error.t` variant structure: transient vs permanent, retryability
- Driver matrix: caqti-driver-postgresql (libpq), caqti-driver-sqlite3
  (libsqlite3), caqti-driver-mariadb (libmariadb)
- Any documented hooks for tracing, cancellation, or pool health

## What CQ-1 does NOT produce

- Comparison vs pgx (separate question; SQL-A0 outside this epic)
- DIY-wire scope estimate (separate question)
- Final eta-sql API shape

## Reference reading list

- caqti-eio.opam and dune files
- packages/caqti/lib/caqti_connection_sig.mli (or equivalent)
- packages/caqti-eio/lib/caqti_eio.mli
- packages/caqti/lib/caqti_request.mli
- packages/caqti/lib/caqti_type.mli
- packages/caqti/lib/caqti_error.mli
- One real-world consumer (e.g., dream's caqti integration, ocsigen, etc.)
  for how the API actually feels at the call site
