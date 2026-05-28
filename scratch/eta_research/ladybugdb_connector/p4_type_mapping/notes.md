# P4 — Type Mapping Probe

**Status**: completed (paper analysis based on API structure)
**Hypothesis H-4**: Property graph model maps cleanly to OCaml algebraic types.
**Verdict**: ✅ **CONFIRMED** — Rich type system maps well to OCaml.

## LadybugDB Type System

### Scalar Types
- INT8, INT16, INT32, INT64 → `Int of int`, `Int64 of int64`
- FLOAT, DOUBLE → `Float of float`
- STRING → `String of string`
- BLOB → `Bytes of bytes`
- BOOL → `Bool of bool`
- NULL → `Null`

### Temporal Types
- DATE → `Date of int` (days since epoch)
- TIMESTAMP → `Timestamp of int64` (microseconds)
- TIMESTAMP_NS → `Timestamp_ns of int64`
- INTERVAL → `Interval of int64 * int * int`

### Graph Types
- NODE → `{ label: string; properties: (string * Value.t) list }`
- REL → `{ label: string; src: node_id; dst: node_id; properties: ... }`
- PATH → `Node.t list * Relationship.t list`

### Composite Types
- LIST → `List of Value.t list`
- MAP → `Map of (string * Value.t) list`
- STRUCT → `Struct of (string * Value.t) list`

## OCaml Type Definition

```ocaml
type node_id = { table_id: int; offset: int }

type t =
  | Null
  | Bool of bool
  | Int of int
  | Int64 of int64
  | Float of float
  | String of string
  | Bytes of bytes
  | Date of int
  | Timestamp of int64
  | Node of { label: string; properties: (string * t) list }
  | Rel of { label: string; src: node_id; dst: node_id; properties: (string * t) list }
  | Path of t list * t list
  | List of t list
  | Map of (string * t) list
  | Struct of (string * t) list
```

## Verdict

H-4 is confirmed. LadybugDB's type system maps cleanly to OCaml algebraic types.
