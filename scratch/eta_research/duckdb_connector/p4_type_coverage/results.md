# P4 — DuckDB Type Coverage Inventory

**Status**: completed
**Hypothesis H-4**: DuckDB requires a richer Value type than SQLite's closed 7-case variant.
**Verdict**: ✅ **CONFIRMED** — DuckDB's type system is significantly richer; 6/10 queries require new types.

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

## DuckDB Type System

DuckDB supports these types (from `duckdb_type` enum):
- Boolean: `DUCKDB_TYPE_BOOLEAN`
- Integer: `TINYINT`, `SMALLINT`, `INTEGER`, `BIGINT`
- Unsigned: `UTINYINT`, `USMALLINT`, `UINTEGER`, `UBIGINT`
- Float: `FLOAT`, `DOUBLE`
- Decimal: `DECIMAL` (with width/scale)
- String: `VARCHAR`
- Binary: `BLOB`
- Temporal: `TIMESTAMP`, `DATE`, `INTERVAL`
- Large int: `HUGEINT` (128-bit)
- UUID: `UUID` (16 bytes)
- JSON: `JSON` (alias for VARCHAR with JSON semantics)
- Composite: `LIST`, `STRUCT`, `MAP`
- Other: `ENUM`, `UNION`, `ARRAY`

## 10-Query Type Coverage Analysis

### Query 1: DECIMAL Aggregation
```sql
SELECT SUM(price) FROM orders WHERE region = ?
```
- `price` is `DECIMAL(18,4)`
- Bind: `region` → String ✅
- Result: `SUM(price)` → DECIMAL → **Unsupported** (would need `Decimal of int64 * int`)
- **Verdict**: ❌ Unsupported (DECIMAL cannot roundtrip without information loss)

### Query 2: TIMESTAMP_TZ Window Function
```sql
SELECT event_at, AVG(value) OVER (
  ORDER BY event_at RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW
) FROM events WHERE user_id = ?
```
- `event_at` is `TIMESTAMPTZ`
- Bind: `user_id` → Int64 ✅
- Result: `event_at` → TIMESTAMP → **Unsupported** (would need `Timestamp of int64`)
- **Verdict**: ❌ Unsupported (TIMESTAMP cannot roundtrip)

### Query 3: DATE + INTERVAL Filter
```sql
SELECT * FROM events WHERE created_at >= ? - INTERVAL '30 days'
```
- `created_at` is `DATE`
- Bind: date parameter → **Unsupported** (would need `Date of int`)
- Result: `created_at` → DATE → **Unsupported**
- **Verdict**: ❌ Unsupported (DATE cannot roundtrip)

### Query 4: UUID Primary Key Join
```sql
SELECT u.name, o.total FROM users u JOIN orders o ON u.id = o.user_id WHERE u.id = ?
```
- `u.id` is `UUID`
- Bind: `u.id` → **Unsupported** (would need `Uuid of bytes`)
- Result: `u.id` → UUID → **Unsupported**
- **Verdict**: ❌ Unsupported (UUID cannot roundtrip)

### Query 5: LIST Unnest
```sql
SELECT id, unnest(tags) FROM products
```
- `tags` is `LIST(VARCHAR)`
- Result: `unnest(tags)` → VARCHAR ✅ (but `tags` column itself → **Unsupported**)
- **Verdict**: ⚠️ Partial (LIST column cannot roundtrip, but unnested values can)

### Query 6: STRUCT Field Access
```sql
SELECT id, address.city FROM users WHERE address.city = ?
```
- `address` is `STRUCT(city VARCHAR, street VARCHAR, ...)`
- Bind: `address.city` → String ✅
- Result: `address` → **Unsupported** (would need `Struct of (string * t) list`)
- **Verdict**: ❌ Unsupported (STRUCT cannot roundtrip)

### Query 7: ENUM Filter
```sql
SELECT * FROM orders WHERE status = 'active'::status_enum
```
- `status` is `ENUM('active', 'inactive', 'deleted')`
- Bind: `'active'` → String ✅
- Result: `status` → ENUM → **Unsupported** (would need `Enum of int * string`)
- **Verdict**: ❌ Unsupported (ENUM cannot roundtrip)

### Query 8: BLOB Roundtrip
```sql
INSERT INTO files (data) VALUES (?) RETURNING data
```
- `data` is `BLOB`
- Bind: `data` → Bytes ✅
- Result: `data` → BLOB → Bytes ✅
- **Verdict**: ✅ Supported

### Query 9: Recursive CTE
```sql
WITH RECURSIVE cte AS (
  SELECT id, parent_id, name FROM categories WHERE parent_id IS NULL
  UNION ALL
  SELECT c.id, c.parent_id, c.name FROM categories c JOIN cte ON c.parent_id = cte.id
)
SELECT * FROM cte
```
- All columns are basic types (INTEGER, VARCHAR)
- **Verdict**: ✅ Supported

### Query 10: JSON Extract
```sql
SELECT data->>'name' FROM events WHERE data->>'type' = ?
```
- `data` is `JSON` (alias for VARCHAR with JSON semantics)
- Bind: `data->>'type'` → String ✅
- Result: `data->>'name'` → VARCHAR ✅
- **Verdict**: ✅ Supported (JSON is just VARCHAR with accessor functions)

## Summary Table

| # | Query | Bind | Result | Verdict |
|---|-------|------|--------|---------|
| 1 | DECIMAL aggregation | ✅ String | ❌ DECIMAL | ❌ Unsupported |
| 2 | TIMESTAMP_TZ window | ✅ Int64 | ❌ TIMESTAMP | ❌ Unsupported |
| 3 | DATE + INTERVAL | ❌ DATE | ❌ DATE | ❌ Unsupported |
| 4 | UUID join | ❌ UUID | ❌ UUID | ❌ Unsupported |
| 5 | LIST unnest | ✅ VARCHAR | ⚠️ LIST | ⚠️ Partial |
| 6 | STRUCT access | ✅ String | ❌ STRUCT | ❌ Unsupported |
| 7 | ENUM filter | ✅ String | ❌ ENUM | ❌ Unsupported |
| 8 | BLOB roundtrip | ✅ Bytes | ✅ BLOB | ✅ Supported |
| 9 | Recursive CTE | ✅ basic | ✅ basic | ✅ Supported |
| 10 | JSON extract | ✅ String | ✅ VARCHAR | ✅ Supported |

**Result**: 4/10 fully supported, 1/10 partially supported, 5/10 unsupported.

## Analysis

### Types Missing from Value.t

1. **DECIMAL**: Needs `Decimal of int64 * int` (value, scale) or `Decimal of string`
2. **TIMESTAMP/TIMESTAMPTZ**: Needs `Timestamp of int64` (microseconds since epoch)
3. **DATE**: Needs `Date of int` (days since epoch)
4. **UUID**: Needs `Uuid of bytes` (16 bytes)
5. **LIST**: Needs `List of t list`
6. **STRUCT**: Needs `Struct of (string * t) list`
7. **ENUM**: Needs `Enum of int * string` or `Enum of string`
8. **INTERVAL**: Needs `Interval of int64 * int * int` (months, days, microseconds)

### Impact on Row.get Decoders

Adding these types to `Value.t` would require:
1. New pattern matches in all `Row.get_*` functions
2. New decoder functions (`Row.decimal`, `Row.timestamp`, etc.)
3. Potential breaking changes to existing code that pattern-matches on `Value.t`

### Widening Options

**Option A: Widen Value.t in-place**
- Add new constructors to `Value.t`
- Pros: Simple, no module restructuring
- Cons: Breaking change for existing code, bloats the type for SQLite users

**Option B: Engine-specific Value type**
- `Sql.Engine.Sqlite.Value` with current 7 cases
- `Sql.Engine.Duckdb.Value` with additional cases
- Pros: Clean separation, no breaking changes
- Cons: More complex, requires GADT bridging

## Next Steps

H-4 is confirmed. The connector needs a richer Value type. The exact shape (Option A vs B) will be decided in **P8** (engine generalization).
