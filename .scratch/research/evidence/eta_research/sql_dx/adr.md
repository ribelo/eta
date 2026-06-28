# ADR — Sql typed-builder surface reshape

**Worktree:** `../Eta-sql-dx`  
**Branch:** `research-sql-dx`  
**Date:** 2026-05-28  
**Scope:** `lib/sql/eta_sql.{ml,mli}` public surface  
**Mode:** research only — zero edits under `lib/`

---

## Verdict

**(c) Reshape.**

The current typed-builder surface (`Source`, `Expr`, `Projection`) cannot
express join-heavy or predicate-rich workloads without forcing raw-SQL escape.
Both load-bearing hypotheses (H1 joins, H2 expressions) were rejected by
compilation fixtures. The execution-surface fragmentation (H6–H8) was not
fully tested but is visible in the `.mli` and the prior-art cross-tab.

This ADR proposes a reshape of `Source` and `Expr`, and a surface collapse
of `Connection`/`Pool`/`Eta_pool` into a single execution path.

---

## Evidence trace

### H1 — Joins capability: REJECTED

**Disproof signature:** A 4-table query needs >2× the call-site LOC of the same
query in sqlx-Rust or Caqti, **or** breaks the `'scope` chain and forces raw SQL.

**Evidence:** `.scratch/eta_research/sql_dx/p1_joins/fixture.ml`

The fixture attempts:
```ocaml
Q.Source.inner_join join_2 Comments.table
  ~on:(Q.Join.on_eq Posts.id Comments.post_id)
```

Compilation produces:
```
Error: This expression has type "(Users.table * Posts.table) Q.Source.t"
       but an expression was expected of type "'a Q.table"
```

**Root cause:** `Source.inner_join` and `Source.left_join` are closed on
`'left table -> 'right table`, not on `Source.t -> 'table table`. The join
surface is hard-limited to exactly 2 tables.

**Verdict:** The typed builder is structurally incapable of N>=3 joins.
This is not a missing combinator (which would be "expand combinators" verdict
(b)). It is a surface-shape problem: the `'scope` type is a product of two
table types, and there is no way to extend it.

### H2 — Expression compositionality: REJECTED

**Disproof signature:** `WHERE col1 < col2 + 5`, `WHERE NOT (a OR (b AND c))`,
`WHERE col IN (lit, lit, lit)`, `WHERE col BETWEEN x AND y`,
`CASE WHEN ... THEN ... END` cannot be expressed without raw-SQL escape.

**Evidence:** `.scratch/eta_research/sql_dx/p2_expressions/fixture.ml`

| Predicate | Attempt | Result |
|---|---|---|
| Column arithmetic | `Expr.(lt Items.width (Items.height + 5))` | Type error: `column` expected, got `int` |
| BETWEEN | `Expr.(between Items.id 10 20)` | Unbound value `between` |
| IN-list | `Expr.(in_list Items.status ["active"; "pending"])` | Unbound value `in_list` |
| CASE WHEN | `Expr.(case [(gt Items.score 90, "A"); ...] ~default:"C")` | Unbound value `case` |

**Verdict:** `Expr` is missing operators that appear in realistic workloads.
Unlike H1, this *could* be addressed by adding combinators (verdict (b)),
but the combination with H1 makes a reshape more appropriate: the expression
and join surfaces are interdependent (join conditions are `Expr.t`), and
patching one while the other remains structurally broken would leave the
surface in an incoherent state.

### P3–P10 — Deferred

H3–H10 were **not tested** with fixtures. Their status is **Deferred**.
Desk-check observations exist in `results.md`, but they do not satisfy the
"no verdict without captured run log" rule. The halt condition triggered after
P2, so P3–P10 were not run.

---

## Reshape proposal

### 1. Join surface: generalize `Source` to an extensible product

**Current shape:**
```ocaml
val inner_join : 'left table -> 'right table -> on:('left * 'right) Expr.t -> ('left * 'right) t
val left_join  : 'left table -> 'right table -> on:('left * 'right) Expr.t -> ('left * 'right) t
```

**Problem:** Closed on `'table`. Cannot compose N>=2.

**Proposed shape (inspired by Petrol's `Query.join`):**
```ocaml
val join :
  ?op:[`Inner | `Left] ->
  on:'scope Expr.t ->
  'scope Source.t ->
  ('scope * 'new) Source.t
```

Or, if keeping table-level start:
```ocaml
val from : 'table table -> 'table Source.t
val join :
  ?op:[`Inner | `Left] ->
  on:'scope Expr.t ->
  'new table ->
  'scope Source.t ->
  ('scope * 'new) Source.t
```

This keeps the `'scope` chain open: each join extends the product type.
Self-joins become possible by passing a different generative module (same as
today, but now chainable).

**Steel-man against this proposal:** Extensible products produce unwieldy
types for N>=4: `((((a * b) * c) * d) * e)`. OCaml's type printer and error
messages become noisy. However, this is the cost of any statically-typed
builder; Drizzle avoids it by using TypeScript's structural typing and
flattened object shapes. For OCaml, the alternative is raw SQL (Caqti/sqlx-Rust
path), which forfeits type safety entirely. The extensible-product path is
strictly better than the current 2-table ceiling.

### 2. Expression surface: expand `Expr` with real operator coverage

**Add:**
- Arithmetic: `add`, `sub`, `mul`, `div` on columns and literals.
- Column-vs-column ordering: `gt_col`, `ge_col`, `lt_col`, `le_col`.
- `between : ('scope, 'a) column -> 'a -> 'a -> 'scope Expr.t`
- `in_values : ('scope, 'a) column -> 'a list -> 'scope Expr.t`
- `case : ('scope Expr.t * 'a) list -> default:'a -> ('scope, 'a) column -> 'scope Expr.t`
  (or similar shape — `case` needs design because it introduces a new type
  parameter for the result type).

**Note:** `case` may require GADT changes or a simpler encoding (e.g.,
`sql_case : when_then:(string * string) list -> else_:string -> string Expr.t`
for string-typed results). This is a design detail for the reshape worktree.

### 3. Execution surface: collapse to one path

**Current:** `Connection`, `Pool`, `Eta_pool` — 3 surfaces.

**Evidence:** All prior art (Caqti, sqlx-Rust, Drizzle, Petrol, Riot sqlx)
ships 1 execution surface. Eta's own README documents `Connection` and `Pool`
as "not the evidence-backed Eta execution surface."

**Proposal:**
- Make `Eta_pool` the only public execution surface.
- Hide `Connection` and `Pool` as internal implementation details, or move
them to a `private`/`internal` module.
- Remove `tx_*` prefix duplication by unifying on a phantom-tagged runner:
```ocaml
type ('kind, 'a) runner
val select : ('pool, 'a) runner -> 'a Compiled.select -> ('a list, error) Eta.Effect.t
val with_transaction : ('pool, 'a) runner -> (('tx, unit) runner -> ('b, error) Eta.Effect.t) -> ('b, error) Eta.Effect.t
```

This eliminates `tx_select`, `tx_fold_select`, `tx_returning`,
`tx_execute_compiled`, `tx_run_schema` (~80% of the tx surface).

**Steel-man against this proposal:** `Connection` is useful for synchronous
unit tests. However, tests can use `Eio_main.run` + `Eta_pool` just as easily.
The existing `test_sql.ml` already does this for `Eta_pool` tests.

### 4. Pool-default kwargs

**Proposal:** Move `~blocking_pool` and `~timeout` to `Eta_pool.create` with
optional override on individual calls:
```ocaml
val create :
  ?name:string ->
  ?max_size:int ->
  ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
  ?timeout:Eta.Duration.t ->
  Sqlite.config -> (t, error) Eta.Effect.t

val query : ?timeout:Eta.Duration.t -> t -> string -> Value.t list -> (Row.t list, error) Eta.Effect.t
```

Call-site noise drops measurably (see `test_sql_eta_pool_typed_compiled_queries`
in `test_sql.ml` for the current verbosity).

---

## Gaps that survive the proposal

These gaps were **not tested** (P3–P10 are Deferred). The reshape proposal
addresses the known failures (H1, H2). The following remain open questions:

| Gap | Evidence needed to change recommendation |
|---|---|
| Record projections (H3) | Fixture showing `Projection.map` is insufficient for 6-of-12 partial decode |
| Aggregations: avg/min/max (H4) | Fixture showing multi-aggregate + aggregate HAVING is expressible after Expr expansion |
| Correlated subqueries (H5) | Fixture showing outer-scope reference in inner `Select` |
| Migrate right-sizing (H9) | Coverage matrix showing >50% of public verbs are unused |
| Raw escape rate (H10) | Computed rate over the full corpus after the reshape |

If any of H3–H5 falsifies after the reshape, the surface may need a second
reshape iteration. H6–H8 are structural and addressed by the collapse proposal.

---

## Acceptance criteria for the reshape worktree

When this reshape is implemented (separate worktree, not this lab):

1. A 4-table mixed inner/left join compiles and produces correct SQL.
2. `Expr.between`, `Expr.in_values`, and column arithmetic compile and produce
correct SQL.
3. `Eta_pool` is the only public execution module.
4. `tx_*` prefix duplication is eliminated (unified runner).
5. `~blocking_pool` is pool-default; `~timeout` is pool-default with per-call
override.
6. All existing tests in `test/sql/test_sql.ml` pass without loss of behavior.
7. No new dependencies beyond current `eta_sql` closure.

---

## What would change this recommendation

- **Evidence that Source.t can be extended via a lighter mechanism** (e.g.,
  a `Source.join_source` constructor that takes `Source.t` and a table) would
  reduce the reshape to "expand combinators" ((b)) for joins.
- **Evidence that `Expr` can be expressed via a separate sub-DSL** (e.g.,
  `Sql_expr.(col width + lit 5)`) would reduce the reshape to "expand
  combinators" for expressions.
- **Evidence that H3–H5 are all accepted** after the join+expr expansion would
  support a "mixed" verdict: keep top-level structure, expand combinators.

However, H1 is not addressable by adding a single combinator — the `'scope`
type is structurally closed at 2 tables. H2 requires ~6 new combinators plus
potential GADT work for `case`. The combination justifies a reshape, not
piecemeal expansion.

---

## Closure pass — sketch verification (2026-05-28, redo)

The three proposed API shapes were compile-checked with real type constraints
in `.scratch/eta_research/sql_dx/p_sketch/`. Each sketch demonstrates both
valid use (compiles) and invalid use (rejected by type checker).

### Source.join — 4-table chainable joins

**Status:** COMPILES with column promotion

The extensible-product type composes for 4 tables. Column scope promotion
(`cast_scope`) is required when referencing columns from a combined scope.
The type system correctly rejects using columns from the wrong scope.

**Finding:** The rebuild worktree must implement column promotion
(`cast_scope : ('old, 'a) column -> ('new, 'a) column`). This is a usability
concern — users must explicitly promote columns. A type-class or
auto-promotion mechanism could help, but adds complexity.

**Implication:** The rebuild worktree can use this shape. Column promotion
is the main ergonomic cost. No GADTs needed for the core types.

**Soundness warning:** `cast_scope` as written is a polymorphic cast that
lets any column masquerade as any scope — it performs no containment check.
The sketch proves the *shape* composes, but the rebuild worktree must
design a containment witness (e.g., a type-level proof that the target
scope includes the column's table) rather than a blind cast. Without this,
column promotion would accept nonsensical scopes like `[`tags] where
[`users] * [`posts]` is expected.

### Expr.case — CASE WHEN expressions

**Status:** COMPILES with result type parameterization

The case expression type composes for different result types (string, int).
The type system correctly rejects mixing result types in branches.

**Finding:** The expression type must be parameterized by both scope and
result type: `('scope, 'a) expr`. This allows the case expression to carry
its result type through to a downstream Projection. The GADT constructor
for `Case` is what makes branch-type-mixing rejected — without it, OCaml
would unify the result types across branches.

**Implication:** The rebuild worktree can use this shape. A GADT constructor
for the case expression is required to enforce branch-type consistency.

### ('kind, 'a) runner — unified execution carrier

**Status:** COMPILES with discrimination

The runner type discriminates between pool and tx contexts. The type system
correctly rejects using a pool runner where a tx runner is expected.

**Finding:** A transparent type alias (`type ('kind, 'a) runner = 'a`) does
not discriminate — OCaml's type system unifies the phantom types. The
rebuild worktree must use either an abstract phantom type (with module
boundary hiding the representation) or a GADT to enforce the
discrimination.

**Implication:** The rebuild worktree must choose one of:
- Abstract phantom type with module-private representation
- GADT: `type ('kind, 'a) runner = Pool_runner : 'a -> ... | Tx_runner : 'a -> ...`

### Gaps resolved

All three proposed API shapes compile in OCaml with real type constraints.
The main findings are:
1. Column scope promotion (`cast_scope`) is needed for the join API, but
   the polymorphic cast is unsound — the rebuild must design a containment
   witness
2. Runner discrimination requires either an abstract phantom type or a GADT
   (transparent alias does not discriminate)
3. Expr.case requires a GADT constructor to enforce branch-type consistency
