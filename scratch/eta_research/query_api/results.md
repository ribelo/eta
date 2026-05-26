# SQL Query API Results

Status: P5 production SQL surface fixture added for the review-requested
SQLite features.

## Current Verdict

Candidate A, generative table modules plus a typed builder, is the first eta-sql
query API shape. PPX is not required for the first slice because the selected
surface already gives typed columns, same-table composition, prepared binding,
and typed row decoding with ordinary OCaml modules.

The previous structural gap is closed for the review-requested surface: typed builder values compile
to opaque SQL+parameter+decoder artifacts, and Sql.Eta_pool can execute compiled
schema, change, select, and batched select-fold operations with the same timeout
and sqlite3_interrupt cancellation discipline as raw SQL.

The production SQL surface is also broader than the first slice: fixtures and
package tests now cover DISTINCT, COUNT, SUM, GROUP BY, HAVING, subquery
predicates, CTEs, UPSERT/ON CONFLICT, RETURNING for INSERT/UPDATE/DELETE, and
ROW_NUMBER window projection.

PPX is untested for this API shape. A raw-SQL validation PPX would be a
separate feature with a different goal; it cannot be marked rejected until a PPX
fixture expresses the same operations and fails the stated criteria.

## Evidence

Run:

~~~sh
nix develop .#oxcaml -c dune build scratch/eta_research/query_api/p0_api_candidates.exe
nix develop .#oxcaml -c ./_build/default/scratch/eta_research/query_api/p0_api_candidates.exe
~~~

Expected output:

~~~text
builder_rows=2 first=Ada updated=1 deleted=1
raw_rows=2 first=Ada
generated_name=Grace
~~~

Typed Eta_pool fixture:

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/query_api/p1_eta_pool_typed.exe
~~~

Observed output:

~~~text
typed_eta_rows=2 first=Ada sum=3 sql=SELECT \"users\".\"id\", \"users\".\"name\" FROM \"users\" WHERE \"users\".\"active\" = ? ORDER BY \"users\".\"id\" ASC params=1
~~~

Expanded query surface fixture:

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/query_api/p2_query_surface.exe
~~~

Observed output:

~~~text
surface_subquery=2 cte=2 window_last=3 grouped=2
surface_returning=1 upsert_c2=100 tx_eight_sum=74
~~~

Observed output:

~~~text
builder_rows=2 first=Ada updated=1 deleted=1
raw_rows=2 first=Ada
generated_name=Grace
~~~

Package gates:

~~~text
nix develop .#oxcaml -c dune runtest packages/sql --force
Result: eta-sql passed 30 Sql and Sqlite tests.

nix develop .#oxcaml -c dune build --profile release packages/sql packages/eta
Result: passed.
~~~

Wrong-table negative fixture:

~~~sh
nix develop .#oxcaml -c sh -lc 'ocamlopt -I _build/default/packages/sql/.sql.objs/byte -c scratch/eta_research/query_api/wrong_table_negative.ml'
~~~

Relevant compiler output:

~~~text
Error: This expression has type
         "(Posts.table, int) Q.Projection.t"
       but an expression was expected of type "(Users.table, 'a) Q.Projection.t"
       Type "Posts.table" = "Posts.T.table" is not compatible with type
         "Users.table" = "Users.T.table"
~~~

## Cross-Tab

| Criterion | A typed builder | B raw request | C PPX generated request shape |
| --- | --- | --- | --- |
| CRUD expressiveness | Covers SELECT/INSERT/UPDATE/DELETE, DISTINCT, COUNT, SUM, GROUP BY, HAVING, subqueries, CTEs, UPSERT, RETURNING, ROW_NUMBER, and compiled Eta_pool execution in fixtures/tests | Expresses any SQL string, but every operation repeats bind/decode code | Expresses one generated query at a time |
| Static table safety | Phantom table identity prevents mixing columns/predicates across tables | None | Untested; SQL validator could catch strings, generated functions may or may not compose like Drizzle |
| Bind safety | Values are bound as typed column values | Manual binder can drift from SQL placeholders | Generated binder can be correct if PPX parses SQL |
| Row decoding | Row descriptors decode typed tuples/options, including an 8-column package fixture | Manual decoder per request | Generated decoder possible |
| Call-site ergonomics | OCaml pipeline over table/column values | SQL string plus bind/decode record | Good for raw SQL literals, less Drizzle-like |
| Dependency/build cost | Lives in eta-sql with the Sqlite connector | No new dependency | Requires PPX implementation and generated-code debugging |

## Decision Diary

V-Query-0 - Select the typed builder for the first slice.
Decision: Promote Candidate A as Sql in packages/sql.
Evidence: The P0 fixture gives comparable behavior to raw requests and a
generated-request shape while preserving composability. Package tests cover
CRUD, nullable/bool decoding, stable rendering, invalid query errors, many-row
find_opt rejection, joins, schema helpers, pool/connection helpers, and migrations.
Counterevidence considered: PPX can validate raw SQL literals and remove
manual bind/decode boilerplate. That is valuable for a raw-SQL API, but no PPX
fixture has been run yet. PPX is deferred, not rejected.
Confidence: Medium.
Would change if: joins, aggregations, or migrations require SQL syntax that the
host-language builder cannot express without becoming materially worse than a
small PPX, or if a PPX fixture beats the builder on the same Drizzle-like
authoring criteria.

V-Query-1 - Compile typed builder values for Eta_pool.
Decision: Add Sql.Compiled and Sql.Eta_pool typed execution functions instead of
forcing production callers to choose between table-safe queries and Eta
scheduling discipline.
Evidence: p1_eta_pool_typed runs schema creation, typed inserts, typed select,
and typed batched fold through Sql.Eta_pool. Package tests include an 8-column
typed compiled Eta_pool fixture.
Counterevidence considered: low-level raw SQL execution still exists for probes
and support code, but the documented production path is compiled typed queries
through Sql.Eta_pool. The typed surface now covers the review-requested P5
constructs.
Confidence: Medium.
Would change if: the full SQLite surface forces enough raw SQL escape hatches
that a PPX raw-SQL validator beats the builder on safety and ergonomics.

V-Query-2 - Add aggregate/grouping surface.
Decision: Add first-class DISTINCT, COUNT, SUM, GROUP BY, and HAVING helpers to
the typed builder.
Evidence: packages/sql tests exercise aggregate selection, distinct rows, and
group filtering through HAVING.
Counterevidence considered: the aggregate expression surface is intentionally
small and count-focused; broader aggregate expression algebra may still be
needed after a real consumer appears.
Confidence: Medium for common aggregate queries.

V-Query-3 - Close the review-requested SQLite surface.
Decision: Add typed helpers for subquery predicates, CTE attachment,
UPSERT/ON CONFLICT, INSERT/UPDATE/DELETE RETURNING, and ROW_NUMBER window
projection.
Evidence: p2_query_surface exercises subquery, CTE, ROW_NUMBER, UPSERT
RETURNING, typed eight-column Eta execution, and transaction-scoped typed fold.
Package tests also cover UPDATE and DELETE RETURNING through Eta_pool.
Counterevidence considered: this is feature parity for the requested surface,
not a full expression algebra for every SQLite grammar production.
Confidence: Medium.
