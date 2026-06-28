# LadybugDB Connector ADR

Status: lab closed for implementation planning
Date: 2026-05-27
Evidence root: .scratch/research/evidence/eta_research/ladybugdb_connector/

## Decision

Ship LadybugDB under a new graph package/module, separate from sql.

Cypher is not SQL, and LadybugDB returns graph values (NODE, REL, PATH) that do not fit the relational sql Value.t without hiding important structure. The driver should live under lib/graph/ or the repo's package equivalent and expose a graph-specific value/result model.

## Public Shape

Initial module sketch:

- Graph.Database
  - open_ : path:string -> Database.t Effect.t
  - close : Database.t -> unit Effect.t
- Graph.Connection
  - connect : Database.t -> Connection.t Effect.t
  - close : Connection.t -> unit Effect.t
  - interrupt : Connection.t -> unit
- Graph.Pool
  - create : Database.t -> (Connection.t, error) Pool.t Effect.t
  - shutdown : pool -> unit Effect.t
- Graph.Query
  - query : Connection.t -> cypher:string -> Row.t list Effect.t
  - query_arrow : Connection.t -> cypher:string -> Arrow_result.t Effect.t
  - prepare / bind / execute for named Cypher parameters
- Graph.Value
  - Null
  - Bool of bool
  - Int of int64
  - Float of float
  - String of string
  - Bytes of bytes only after a real blob-bind path is found
  - List of t list
  - Map of (string * t) list
  - Node of node
  - Rel of rel
  - Path of path

Node should include label, internal id, and typed properties. REL/PATH are not yet decoded by the lab and should be implemented behind focused tests before being advertised as complete.

## Eta Primitives Used

- Effect.blocking for lbug_connection_query.
- Effect.blocking ~on_cancel:lbug_connection_interrupt for timeout/cancellation.
- Effect.timeout at callers.
- Effect.acquire_release for database and connection lifetimes.
- Eta.Pool for bounded connection pooling.

No new Eta primitive is required by the evidence gathered so far.

## Type Mapping

Use Arrow C-data for result decoding.

P-Lbug-1 showed RETURN p produces an Arrow root struct with one p child; p is a struct with _ID, _LABEL, and declared property children. A minimal binding decoded label, internal id, int64, string, and bool properties into an OCaml record.

Known type gaps:

- REL and PATH not decoded.
- Null/list/map decoding from Arrow not tested.
- UUID and bytes not tested.
- Blob parameter binding is blocked by the visible C API: no lbug_value_create_blob or prepared_statement_bind_blob was found in lbug.h.

## Parameterization

Named Cypher parameters work for:

- string
- int64
- double
- bool
- null via lbug_value_create_null + bind_value
- list via lbug_value_create_list + bind_value
- map via lbug_value_create_map + bind_value

Bytes remain Untested until a blob constructor or bind API is found.

## Cancellation Strategy

Use lbug_connection_interrupt as the cancellation hook for started blocking queries.

P-Lbug-2 showed Effect.timeout at 200ms calls on_cancel once, returns Timeout, and leaves the connection reusable. The binding should convert interrupted query returns into a typed timeout/interrupted path, not raise a defect from the worker after timeout cancellation.

## Error Strategy

The C API has only LbugSuccess/LbugError as structured state. Query-result error strings carry the useful diagnostics:

- Parser exception -> Query_syntax
- Binder exception -> Type_mismatch
- Runtime exception with duplicated primary key -> Integrity_violation
- Interrupted. -> Timeout_or_interrupt
- Closed/invalid OCaml-owned handle -> Connection_closed_or_invalid
- fallback -> Other of string

The driver must read lbug_query_result_get_error_message before destroying failed query results. lbug_get_last_error returned unknown in the P-Lbug-4 query failure fixtures.

## Pool Lifecycle

Use Database as parent resource, Pool as child resource, and Connection as pooled resource.

Supported close order:

1. Pool.shutdown
2. pooled connection release/destroy
3. database destroy

P-Lbug-6 safe ordering passed. Unsafe database close while pool remains alive did not crash in the isolated child, but later pooled connection use failed. Do not support that ordering.

## Known Gaps Before v0.1 Implementation Completes

- Full 30-second P-Lbug-5 fairness window remains unproven; only a 5-second run passed.
- Blob/bytes parameter binding is Untested.
- REL/PATH Arrow decoding is Untested.
- OOM and filesystem/open error categories were not measured.
- Multi-row/multi-chunk Arrow allocation profile was not measured.
- File-backed pool lifecycle was not measured.
