# Results — per-probe verdicts

## Methodology note

P1 and P2 are the load-bearing hypotheses (OBJECTIVE.md §4). Both triggered
halt conditions. P3–P10 were **not run as full fixtures** because the lab
stopped after P2. Their status is **Deferred** (untested ≠ rejected).

Desk-check observations for P3–P10 are recorded below for completeness, but
they are **not verdicts** and do not satisfy the "no verdict without captured
run log" rule.

---

## P0 — Prior-art surface inventory

**Status:** Complete  
**Artifact:** `prior_art.md`

Key calibration findings:
- No OCaml prior art ships a typed builder with chainable N-table joins.
- Drizzle (TS) and sqlx-Rust are the DX bar-setters.
- All prior art ships 1 top-level execution surface. Eta is the outlier with 3.

---

## P1 — H1 Joins

**Status:** REJECTED (fixture evidence)  
**Artifact:** `p1_joins/run.log`, `p1_joins/fixture.ml`

**Evidence:**
- `Source.inner_join` and `Source.left_join` take `'left table -> 'right table`,
  not `Source.t -> 'table table`.
- 3-table join attempt fails with:
  ```
  Error: This expression has type "(Users.table * Posts.table) Q.Source.t"
         but an expression was expected of type "'a Q.table"
  ```
- Self-join is possible with two generative `Table.Make` modules, but awkward.
- Lateral joins are unsupported.

**Verdict:** The typed builder is closed at exactly 2 tables. Any N>=3 join
workload forces raw-SQL escape. This is a reshape-level gap.

---

## P2 — H2 Expression compositionality

**Status:** REJECTED (fixture evidence)  
**Artifact:** `p2_expressions/run.log`, `p2_expressions/fixture.ml`

**Evidence:**
- Column arithmetic: `Expr.(lt Items.width (Items.height + 5))` fails because
  `Expr` has no arithmetic operators and `lt` expects a literal, not a column.
- BETWEEN: `Expr.between` is unbound.
- IN-list: `Expr.in_list` is unbound (only `in_select` for subqueries exists).
- CASE WHEN: `Expr.case` is unbound.

**Verdict:** `Expr` cannot express common real predicates. This is a
reshape-level gap (expression surface needs expansion) or an acceptance of
narrow expressivity.

---

## P3 — H6 Surface fragmentation

**Status:** Deferred (halted after P1/P2)  
**Desk-check observation only (not proven):**
- Three execution modules exist: `Connection`, `Pool`, `Eta_pool`.
- All prior art surveyed ships 1 execution surface.
- Eta's own README says "Production Eta code should prefer `Eta_pool`."
- The fragmentation may be unjustified, but this was not tested with a
  call-site inventory or a unified-runner sketch.

**What would close it:** Count call sites in test_sql.ml and lib consumers;
rewrite 3 sites to a unified surface; measure if tests still pass.

---

## P4 — H7 Tx duplication

**Status:** Deferred (halted after P1/P2)  
**Desk-check observation only (not proven):**
- `Eta_pool` exports 5 `tx_*` functions mirroring non-tx versions.
- Prior art solves this with unified carriers (Executor trait, callback scope).
- A sketch showing ≥80% reduction was not built.

**What would close it:** Sketch a phantom-tagged `('kind, 'a) runner` or
first-class module carrier; rewrite 5 tx_* sites; verify tests pass.

---

## P5 — H8 Per-call kwargs

**Status:** Deferred (halted after P1/P2)  
**Desk-check observation only (not proven):**
- Every `Eta_pool` operation requires `~blocking_pool` and `~timeout`.
- No prior art requires both on every call.
- A pool-default-with-override sketch was not built.

**What would close it:** Sketch pool-default override; rewrite 10 call sites;
measure noise reduction; verify no loss of cancellation precision.

---

## P6 — H3 Record projection

**Status:** Deferred (halted after P1/P2)  
**Desk-check observation only (not proven):**
- `Projection` exports `one`, `t2`–`t8`, `count`, `sum_int`, `row_number`, `map`.
- No `Projection.record` or automatic struct mapping in the core builder.
- `ppx_eta` generates record projections for full-table selects, but not
  arbitrary partial ones.
- No fixture was built measuring "places to change when adding a column."

**What would close it:** Build a 6-of-12 column fixture; compare LOC to
sqlx `query_as!` and Caqti tuples; count fragility metric.

---

## P7 — H4 Aggregations

**Status:** Deferred (halted after P1/P2)  
**Desk-check observation only (not proven):**
- `Projection` has `count`, `sum_int`, `row_number`.
- Missing: `avg`, `min`, `max`, `sum_float`.
- `having` takes `Expr.t`, but `Expr` has no aggregate constructors beyond
  special-cased `count_eq`, `count_gt`, `count_ge`.
- Aggregate-vs-aggregate HAVING was not tested with a fixture.

**What would close it:** Build fixtures for `AVG(latency)` and
`HAVING SUM(amount) > AVG(amount)`; attempt typed expression; record result.

---

## P8 — H5 Subqueries

**Status:** Deferred (halted after P1/P2)  
**Desk-check observation only (not proven):**
- `Expr.in_select` and `Expr.exists` exist.
- `Select.with_cte` exists.
- Correlated subqueries: inner `Select` has a separate `'scope` from outer.
  No mechanism to open the outer scope in the inner query. Not tested with
  a fixture.
- Lateral joins: unsupported by SQLite and the builder.

**What would close it:** Build a correlated subquery fixture referencing an
outer column; record compilation result.

---

## P9 — H9 Migrate right-sizing

**Status:** Deferred (halted after P1/P2)  
**Desk-check observation only (not proven):**
- `Migrate` public API includes `list_applied`, `run`, `run_to`, `undo`, plus
  error variants.
- Tests exercise `run`, `run_to`, `undo`, `list_applied`, checksum validation,
  dirty detection, version mismatch, version missing.
- `Version_not_present` error variant may be unused. Not verified.
- No coverage matrix was built.

**What would close it:** Inventory every public value in `Migrate`; cross-
reference against test suite; produce coverage matrix.

---

## P10 — H10 Raw escape rate

**Status:** Deferred (halted after P1/P2)  
**Desk-check observation only (not proven):**
- H1 and H2 rejections force raw SQL for joins >2 tables and for several
  expression patterns.
- The 15-query workload corpus estimates a >50% raw-escape rate, but this
  was not computed from actual typed-path attempts on each query.

**What would close it:** For each of the >=15 queries in workload_corpus.md,
attempt a typed-path expression; count successes vs. raw-SQL falls.

---

## Surprise findings (from actual fixtures)

1. **Source.t is abstract with no escape hatch.** Unlike `Expr.t` (which has
   `sql` and `params` internally but is abstract), `Source.t` cannot be
   constructed from raw SQL at all. This means even a 3-table join with a
   perfectly safe predicate has no typed entry point. The gap is absolute.

2. **Self-join requires two Table.Make modules.** The generative nature of
   `Table.Make` means self-joins need duplicate module declarations. This is
   a DX papercut that could be fixed with a lightweight table alias mechanism.

3. **Projection.map exists but is unused in tests.** The test suite uses only
   `one` and `t2`–`t8`. No test uses `map` to convert tuples to records.
   This suggests the tuple-first design is the dominant idiom internally.

4. **Expr compiles column-vs-literal comparisons but not column-vs-column
   beyond equality.** `eq_col` exists, but no `gt_col`, `lt_col`, etc.
   This is an odd asymmetry — equality is special-cased but ordering is not.
