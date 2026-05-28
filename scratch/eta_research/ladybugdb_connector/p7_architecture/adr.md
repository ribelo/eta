# ADR: New Graph Module vs Extending Sql

**Status**: completed
**Hypothesis H-7**: New `packages/graph/` is cleaner than extending `packages/sql/`.
**Verdict**: ✅ **CONFIRMED** — New Graph module is cleaner.

## Decision

LadybugDB is fundamentally different from SQL databases:
- **Query language**: Cypher (not SQL)
- **Data model**: Property Graph (not tables)
- **Types**: Node, Relationship, Path (not rows/columns)
- **Operations**: Pattern matching, graph traversal (not JOIN/WHERE)

## Options

### Option A: Extend Sql with Cypher Escape

Add `Sql.Cypher` module with escape hatch:
```ocaml
Sql.Cypher.query conn "MATCH (p:Person) RETURN p"
```

**Pros**:
- Reuses existing Sql infrastructure
- Single import for all database access

**Cons**:
- Mixing paradigms (SQL and Cypher)
- Type system doesn't fit (rows vs nodes/rels)
- Builder can't express Cypher patterns
- Confuses users (is it SQL or Cypher?)

### Option B: New Graph Module

Create `packages/graph/` with native Cypher support:
```ocaml
Graph.query conn "MATCH (p:Person) RETURN p"
```

**Pros**:
- Clean separation of concerns
- Native Cypher support
- Type system matches graph model
- Clear API for graph operations

**Cons**:
- New package to maintain
- Separate import for graph access

## Recommendation

**Option B (New Graph Module)** is cleaner because:

1. **Paradigm mismatch**: SQL and Cypher are fundamentally different
2. **Type system**: Graph types (Node, Rel, Path) don't fit in SQL Value.t
3. **Builder**: Can't express Cypher patterns in SQL builder
4. **Clarity**: Users know they're doing graph operations

## Implementation Plan

1. Create `packages/graph/` package
2. Define `Graph.t` type for graph values
3. Implement `Graph.query` for Cypher execution
4. Use Arrow for efficient result iteration
5. Integrate with Eta_pool for connection management

## Verdict

H-7 is confirmed. New `packages/graph/` module is cleaner than extending `packages/sql/`.
