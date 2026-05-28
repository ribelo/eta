# Workload corpus

~15 queries covering projected real consumers, Riot sqlx test lift, and
synthetic complex set. Each query has:
- Plain SQL + intent
- Eta typed-path status (Y/N)
- Notes on Caqti, sqlx-Rust, Riot sqlx, Drizzle, Petrol expression

---

## Q1 — 2-table inner join (positive control)

```sql
SELECT users.name, posts.title
FROM users
INNER JOIN posts ON users.id = posts.author_id
```

**Intent:** Basic relational join.  
**Eta typed path:** Y  
**LOC estimate (Eta):** ~5 lines (Source.inner_join + Select.from_source + Projection.t2)

| API | Shape |
|-----|-------|
| Caqti | Raw SQL string |
| sqlx-Rust | `query_as!` with SQL string |
| Riot sqlx | `Sqlx.query` with SQL string |
| Drizzle | `db.select().from(users).innerJoin(posts, eq(users.id, posts.authorId))` |
| Petrol | `Query.select Expr.[...] ~from:table |> Query.join ~op:INNER ~on:...` |

---

## Q2 — 3-table mixed inner/left join

```sql
SELECT users.name, posts.title, comments.body
FROM users
INNER JOIN posts ON users.id = posts.author_id
LEFT JOIN comments ON posts.id = comments.post_id
```

**Intent:** N>=3 join — projected consumer (eta-otel span attribution).  
**Eta typed path:** N  
**Reason:** `Source.inner_join` and `Source.left_join` are closed on `'table`,
not on `Source.t`. Cannot extend a 2-table source with a third table.

| API | Shape |
|-----|-------|
| Caqti | Raw SQL string |
| sqlx-Rust | `query_as!` with SQL string |
| Riot sqlx | `Sqlx.query` with SQL string |
| Drizzle | Chainable: `.innerJoin(...).leftJoin(...)` |
| Petrol | `Query.join` on query; may pipeline but docs don't show N>=3 |

---

## Q3 — 4-table join with filter

```sql
SELECT u.name, p.title, c.body, t.tag
FROM users u
INNER JOIN posts p ON u.id = p.author_id
INNER JOIN comments c ON p.id = c.post_id
LEFT JOIN tags t ON p.id = t.post_id
WHERE u.active = 1
```

**Intent:** Deep join — projected consumer (eta-ai audit trail).  
**Eta typed path:** N  
**Reason:** Same structural limitation as Q2.

---

## Q4 — Self-join (employee → manager)

```sql
SELECT e.name AS employee, m.name AS manager
FROM employees e
LEFT JOIN employees m ON e.manager_id = m.id
```

**Intent:** Hierarchical self-reference.  
**Eta typed path:** Y (awkward)  
**Reason:** Requires two `Table.Make` invocations for the same table.

| API | Shape |
|-----|-------|
| Caqti | Raw SQL string |
| sqlx-Rust | `query_as!` with SQL string + table alias |
| Drizzle | `alias(employees, 'managers')` then `.leftJoin(managers, ...)` |
| Petrol | Two `declare_table` calls with different names |

---

## Q5 — WHERE col1 < col2 + 5

```sql
SELECT * FROM items WHERE width < height + 5
```

**Intent:** Column-vs-column arithmetic predicate.  
**Eta typed path:** N  
**Reason:** `Expr` has no arithmetic operators (`+`, `-`, `*`, `/`).
`eq_col` exists but `gt_col`, `add`, etc. do not.

| API | Shape |
|-----|-------|
| Drizzle | `lt(items.width, sql`${items.height} + 5`)` or raw `sql` template |
| Petrol | `Expr.(width < height + i 5)` (arithmetic exists) |

---

## Q6 — WHERE NOT (a OR (b AND c))

```sql
SELECT * FROM users WHERE NOT (active = 1 OR (role = 'admin' AND age < 18))
```

**Intent:** Complex boolean tree.  
**Eta typed path:** Y  
**Reason:** `Expr.and_`, `Expr.or_`, `Expr.not_`, `Expr.eq` compose correctly.

---

## Q7 — WHERE col BETWEEN x AND y

```sql
SELECT * FROM events WHERE timestamp BETWEEN 1000 AND 2000
```

**Intent:** Range predicate.  
**Eta typed path:** N  
**Reason:** No `Expr.between`.

| API | Shape |
|-----|-------|
| Drizzle | `between(events.timestamp, 1000, 2000)` |
| Petrol | `Expr.between ~lower:(i 1000) ~upper:(i 2000) events.timestamp` |

---

## Q8 — WHERE col IN (lit, lit, lit)

```sql
SELECT * FROM users WHERE status IN ('active', 'pending', 'verified')
```

**Intent:** Set membership with literals.  
**Eta typed path:** N  
**Reason:** `Expr.in_select` exists for subqueries, but no `Expr.in_values`
or `Expr.in_list` for literal lists.

| API | Shape |
|-----|-------|
| Drizzle | `inArray(users.status, ['active', 'pending', 'verified'])` |
| Petrol | `Expr.in_ (s "active") (...)` (heterogeneous list via expr_list) |

---

## Q9 — CASE WHEN ... THEN ... END

```sql
SELECT
  name,
  CASE WHEN score > 90 THEN 'A'
       WHEN score > 80 THEN 'B'
       ELSE 'C' END AS grade
FROM students
```

**Intent:** Conditional projection.  
**Eta typed path:** N  
**Reason:** No `Expr.case`.

| API | Shape |
|-----|-------|
| Drizzle | `sql` template or `case` expression |
| Petrol | No explicit `case`; would use raw `sql` fallback |

---

## Q10 — GROUP BY with multi-aggregate

```sql
SELECT user_id, COUNT(*), AVG(latency), MAX(latency)
FROM requests
GROUP BY user_id
```

**Intent:** Multi-aggregate grouped analysis — projected consumer (eta-ai token usage).  
**Eta typed path:** N (Tested)  
**Evidence:** `p10_corpus_check/q10/run.log` — single aggregate (count) with GROUP BY compiles as a simpler approximation, but multi-aggregate (count + avg + max) cannot be expressed because Projection.t3 expects columns, not projections. The actual corpus query requires raw SQL.  
**Reason:** `count` exists, but `avg` and `max` are missing from `Projection`.
Only `sum_int` exists for aggregates beyond `count`.

| API | Shape |
|-----|-------|
| Drizzle | `db.select({ userId: requests.userId, count: count(), avgLatency: avg(requests.latency), maxLatency: max(requests.latency) })` |
| Petrol | `Expr.[count []; avg latency; max_of [latency]]` |

---

## Q11 — HAVING with aggregate-vs-aggregate

```sql
SELECT user_id, SUM(amount), AVG(amount)
FROM transactions
GROUP BY user_id
HAVING SUM(amount) > AVG(amount)
```

**Intent:** Aggregate predicate — projected consumer (metric histogram buckets).  
**Eta typed path:** N (Tested)  
**Evidence:** `p10_corpus_check/q11/run.log` — HAVING with count_ge compiles as a simpler approximation, but the real predicate (SUM > AVG) cannot be expressed because Expr has no aggregate constructors. The actual corpus query requires raw SQL.  
**Reason:** `having` takes `Expr.t`, but `Expr` has no aggregate constructors.
Only special-cased `count_eq`, `count_gt`, `count_ge` exist.

| API | Shape |
|-----|-------|
| Drizzle | `.having(({ sumAmount, avgAmount }) => gt(sumAmount, avgAmount))` |
| Petrol | Would need aggregate expressions in `Expr`; not clear if supported |

---

## Q12 — Correlated subquery

```sql
SELECT name FROM users u
WHERE u.id = (SELECT MAX(post_id) FROM posts p WHERE p.author_id = u.id)
```

**Intent:** Correlated subquery — projected consumer (session reconstruction).  
**Eta typed path:** N (Tested)  
**Evidence:** `p10_corpus_check/q12/run.log` — `Expr.(eq Posts.author_id Users.id)` fails with type error: Users.id is a column, not an int. No way to reference outer scope in inner query.  
**Reason:** Inner `Select` has a separate `'scope` from outer `Select`.
No mechanism to reference outer columns in the inner query.

| API | Shape |
|-----|-------|
| Drizzle | `exists(db.select().from(posts).where(eq(posts.authorId, users.id)))` |
| Petrol | `Expr.exists (Query.select ...)` |

---

## Q13 — CTE with recursive traversal

```sql
WITH RECURSIVE tree(id, parent_id, depth) AS (
  SELECT id, parent_id, 1 FROM nodes WHERE parent_id IS NULL
  UNION ALL
  SELECT n.id, n.parent_id, tree.depth + 1
  FROM nodes n
  INNER JOIN tree ON n.parent_id = tree.id
)
SELECT * FROM tree
```

**Intent:** Graph traversal — foreshadows LadybugDB.  
**Eta typed path:** N (Tested)  
**Evidence:** `p10_corpus_check/q13/run.log` — non-recursive CTE compiles, but recursive CTE syntax (UNION ALL with self-reference) cannot be expressed.  
**Reason:** `Select.with_cte` exists, but recursive CTE syntax (`UNION ALL`
with self-reference) cannot be expressed in the typed builder.

---

## Q14 — Pagination by cursor

```sql
SELECT * FROM events
WHERE (timestamp, id) > (?, ?)
ORDER BY timestamp, id
LIMIT 10
```

**Intent:** Keyset pagination.  
**Eta typed path:** Y  
**Reason:** `where` with `and_` + `order_by` + `limit` all exist.
Composite cursor predicate is verbose but expressible.

---

## Q15 — UPSERT with RETURNING

```sql
INSERT INTO items (id, value)
VALUES (1, 100)
ON CONFLICT (id) DO UPDATE SET value = excluded.value
RETURNING id, value
```

**Intent:** Upsert — common write pattern.  
**Eta typed path:** Y  
**Reason:** `Insert.on_conflict_update` + `returning` are both supported.

---

## Escape-rate summary

| Query | Eta typed path | Evidence |
|-------|----------------|----------|
| Q1 2-table join | Y | Inferred (positive control) |
| Q2 3-table join | N | Tested (p1_joins/run.log) |
| Q3 4-table join | N | Tested (p1_joins/run.log) |
| Q4 self-join | Y (awkward) | Inferred |
| Q5 col arithmetic | N | Tested (p2_expressions/neg_arith/run.log) |
| Q6 boolean tree | Y | Inferred |
| Q7 BETWEEN | N | Tested (p2_expressions/neg_between/run.log) |
| Q8 IN-list | N | Tested (p2_expressions/neg_in_list/run.log) |
| Q9 CASE WHEN | N | Tested (p2_expressions/neg_case/run.log) |
| Q10 multi-aggregate | N | Tested (p10_corpus_check/q10/run.log) — single aggregate compiles as approximation; multi-aggregate does not |
| Q11 agg HAVING | N | Tested (p10_corpus_check/q11/run.log) — count_ge HAVING compiles as approximation; SUM > AVG does not |
| Q12 correlated subq | N | Tested (p10_corpus_check/q12/run.log) |
| Q13 recursive CTE | N | Tested (p10_corpus_check/q13/run.log) |
| Q14 cursor pagination | Y | Inferred |
| Q15 UPSERT RETURNING | Y | Inferred |

### Tested escape rate (Q2, Q3, Q5, Q7, Q8, Q9, Q10, Q11, Q12, Q13)

10 queries tested: 10 require raw SQL escape (100%).
Note: Q10 and Q11 compile simpler approximations (single aggregate, count_ge HAVING), but the actual corpus queries cannot be expressed.

### Inferred upper bound (all queries)

15 queries total: 10 require raw SQL escape (67%).
This exceeds the 30% threshold in H10's disproof signature.

### Notes

- Q10 and Q11 compile with simplified typed paths (single aggregate, count_ge HAVING), but cannot express the real predicates (multi-aggregate, aggregate-vs-aggregate). The approximation fixtures are cited as evidence.
- Q13 compiles with non-recursive CTE, but cannot express the recursive self-reference.
- These partial successes are noted but do not change the N status for the actual corpus queries.
