# P4 — Type Coverage Inventory

**Status**: completed (paper analysis)
**Hypothesis H-4**: Turso requires same Value type as SQLite (7-case).
**Verdict**: ⚠️ **PARTIALLY CONFIRMED** — Turso adds VECTOR type, but it can be treated as BLOB.

## Current SQLite Value.t

```ocaml
type t =
  | Null
  | Int of int
  | Int64 of int64
  | Float of float
  | String of string
  | Bool of bool
  | Bytes of bytes
```

## Turso Type System

Turso implements SQLite's type system plus extensions:

- **INTEGER**: 64-bit signed integer
- **REAL**: 64-bit IEEE 754 floating point
- **TEXT**: UTF-8 string
- **BLOB**: Binary data
- **NULL**: Null value
- **VECTOR**: Native vector type for embeddings (Turso-specific)

## 10-Query Type Coverage Analysis

### Query 1: Standard INTEGER
```sql
SELECT id FROM users WHERE id = ?
```
- Bind: `id` → Int64 ✅
- Result: `id` → INTEGER → Int64 ✅
- **Verdict**: ✅ Supported

### Query 2: Standard TEXT
```sql
SELECT name FROM users WHERE name = ?
```
- Bind: `name` → String ✅
- Result: `name` → TEXT → String ✅
- **Verdict**: ✅ Supported

### Query 3: Standard REAL
```sql
SELECT price FROM products WHERE price > ?
```
- Bind: `price` → Float ✅
- Result: `price` → REAL → Float ✅
- **Verdict**: ✅ Supported

### Query 4: Standard BLOB
```sql
SELECT data FROM files WHERE id = ?
```
- Bind: `id` → Int64 ✅
- Result: `data` → BLOB → Bytes ✅
- **Verdict**: ✅ Supported

### Query 5: VECTOR type
```sql
SELECT embedding FROM items WHERE id = ?
```
- Result: `embedding` → VECTOR → **Treat as BLOB/Bytes**
- **Verdict**: ⚠️ Lossy (can roundtrip as bytes, but loses vector semantics)

### Query 6: JSON (as TEXT)
```sql
SELECT json_extract(data, '$.name') FROM events
```
- Result: `json_extract()` → TEXT → String ✅
- **Verdict**: ✅ Supported (JSON is TEXT with accessor functions)

### Query 7: Date/Time (as TEXT/INTEGER)
```sql
SELECT created_at FROM events WHERE created_at > datetime('now', '-7 days')
```
- Result: `created_at` → TEXT or INTEGER → String or Int64 ✅
- **Verdict**: ✅ Supported (SQLite date/time is TEXT or INTEGER)

### Query 8: Boolean (as INTEGER)
```sql
SELECT active FROM users WHERE active = 1
```
- Bind: `active` → Int64 ✅
- Result: `active` → INTEGER → Int64 ✅
- **Verdict**: ✅ Supported (SQLite stores booleans as INTEGER)

### Query 9: NULL handling
```sql
SELECT email FROM users WHERE email IS NULL
```
- Result: `email` → NULL → Null ✅
- **Verdict**: ✅ Supported

### Query 10: Encrypted BLOB
```sql
SELECT secret FROM vault WHERE id = ?
```
- Result: `secret` → BLOB (encrypted) → Bytes ✅
- **Verdict**: ✅ Supported (encryption is transparent to value type)

## Summary Table

| # | Query | Type | Verdict |
|---|-------|------|---------|
| 1 | Standard INTEGER | INTEGER → Int64 | ✅ Supported |
| 2 | Standard TEXT | TEXT → String | ✅ Supported |
| 3 | Standard REAL | REAL → Float | ✅ Supported |
| 4 | Standard BLOB | BLOB → Bytes | ✅ Supported |
| 5 | VECTOR type | VECTOR → Bytes | ⚠️ Lossy |
| 6 | JSON | TEXT → String | ✅ Supported |
| 7 | Date/Time | TEXT/INTEGER → String/Int64 | ✅ Supported |
| 8 | Boolean | INTEGER → Int64 | ✅ Supported |
| 9 | NULL | NULL → Null | ✅ Supported |
| 10 | Encrypted BLOB | BLOB → Bytes | ✅ Supported |

**Result**: 9/10 fully supported, 1/10 lossy (VECTOR).

## Analysis

### VECTOR Type

Turso's VECTOR type is the only addition to SQLite's type system. It can be:
- **Stored as BLOB**: Vector data is binary, fits in Bytes
- **Queried with functions**: `vector_distance_cos()` for similarity search
- **Roundtripped as bytes**: Can read/write VECTOR as BLOB/Bytes

### Implications for Connector Design

- **Value.t unchanged**: The existing 7-case Value.t is sufficient for Turso.
- **VECTOR as Bytes**: Treat VECTOR columns as BLOB/Bytes.
- **Vector functions**: Expose `vector_distance_cos()` as a typed builder extension.

## Verdict

H-4 is partially confirmed. Turso adds VECTOR type, but it can be treated as BLOB/Bytes without breaking the existing Value.t.
