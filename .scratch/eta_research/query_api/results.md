# SQL Query API Results

Status: P7 schema/table PPX fixture added on top of the compiled Eta_pool query
surface.

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

The PPX space is split into three different shapes:

- Builder-generation PPX: not selected for the first query API. It generates
  request modules instead of improving the selected typed-builder surface, and
  the P0 fixture did not need it to reach table-safe CRUD.
- Schema/table PPX: accepted as optional authoring sugar. It removes
  table-module ceremony while expanding to the same generative table module,
  typed columns, records, schema artifact, and compiled Eta_pool path.
- SQL-literal PPX: deferred and untested. It is a different, larger project
  involving SQL parsing or SQLite introspection; it cannot be marked rejected
  until a fixture exists.

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

Schema/table PPX fixture:

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/query_api/p3_schema_ppx.exe
~~~

Observed output:

~~~text
schema_ppx_rows=2 first=Ada active=true sql_equal=true sql=SELECT "users"."id", "users"."name", "users"."active" FROM "users" WHERE "users"."active" = ? ORDER BY "users"."id" ASC
schema_ppx_metadata=true sql=CREATE TABLE "memberships" ("membership_pk" INTEGER PRIMARY KEY, "membership_team" INTEGER  REFERENCES "teams" ("team_pk") ON DELETE CASCADE, "membership_role" TEXT NOT NULL DEFAULT 'member')
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

Schema/table PPX wrong-table negative fixture:

~~~sh
nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_research/query_api/wrong_table_ppx_negative.exe >/tmp/eta_wrong_table_ppx.out 2>&1; code=$?; cat /tmp/eta_wrong_table_ppx.out; test $code -ne 0'
~~~

Relevant compiler output:

~~~text
Error: This expression has type "(Posts.table, posts_row) Q.Projection.t"
       but an expression was expected of type
         "(Users.table, 'a) Q.Projection.t"
       Type "Posts.table" is not compatible with type "Users.table"
~~~

## Cross-Tab

| Criterion | A typed builder | B raw request | C schema/table PPX | D SQL-literal PPX |
| --- | --- | --- | --- | --- |
| CRUD expressiveness | Covers SELECT/INSERT/UPDATE/DELETE, DISTINCT, COUNT, SUM, GROUP BY, HAVING, subqueries, CTEs, UPSERT, RETURNING, ROW_NUMBER, and compiled Eta_pool execution in fixtures/tests | Expresses any SQL string, but every operation repeats bind/decode code | Same as typed builder; it only generates tables, columns, records, and schema | Untested |
| Static table safety | Phantom table identity prevents mixing columns/predicates across tables | None | Preserved by generated generative table modules | Untested; SQL validator could catch strings |
| Bind safety | Values are bound as typed column values | Manual binder can drift from SQL placeholders | Same as typed builder | Generated binder could be correct if PPX parses SQL |
| Row decoding | Row descriptors decode typed tuples/options, including an 8-column package fixture | Manual decoder per request | Generates all-column record projections | Generated decoder possible |
| Call-site ergonomics | OCaml pipeline over table/column values | SQL string plus bind/decode record | Removes table-module ceremony and gives records for all-column projections | Good for raw SQL literals, not yet probed |
| Dependency/build cost | Lives in eta-sql with the Sqlite connector | No new dependency | Requires optional ppx_eta preprocessor | Larger parser/introspection project |

## Decision Diary

V-Query-0 - Select the typed builder for the first slice.
Decision: Promote Candidate A as Sql in packages/sql.
Evidence: The P0 fixture gives comparable behavior to raw requests and a
generated-request shape while preserving composability. Package tests cover
CRUD, nullable/bool decoding, stable rendering, invalid query errors, many-row
find_opt rejection, joins, schema helpers, pool/connection helpers, and migrations.
Counterevidence considered: a schema/table PPX can remove table declaration
ceremony without changing the selected builder, and a SQL-literal PPX can
validate raw SQL literals and remove manual bind/decode boilerplate. Those are
separate shapes. Builder-generation PPX is not selected for this slice; the
schema/table PPX is the next experiment; SQL-literal PPX remains deferred and
untested.
Confidence: Medium.
Would change if: joins, aggregations, or migrations require SQL syntax that the
host-language builder cannot express without becoming materially worse than a
small PPX, or if a SQL-literal PPX fixture beats the builder on the same
Drizzle-like authoring criteria.

V-Query-4 - Add schema/table PPX as optional authoring sugar.
Decision: Add [%%eta.sql.table type users = { ... }] to ppx_eta. The expansion
generates a users_row record, a Users generative table module, typed columns,
Users.all as a record projection, and Users.schema as a Schema.create_table
artifact.
Evidence: p3_schema_ppx compares manual table-module SQL with PPX-generated
SQL, executes the generated record projection through Sql.Eta_pool, returns
users_row records, and checks primary key, uniqueness, not-null, default, and
foreign-key metadata in generated schema SQL. wrong_table_ppx_negative proves
generated table phantom types still reject using Posts.all with Users.table.
Counterevidence considered: this PPX deliberately does not parse SQL literals
and does not replace the typed builder. SQL-literal PPX remains a separate,
untested project.
Confidence: Medium.
Would change if generated schema metadata drifts from the manual builder, or if
real tables routinely need more than the supported field-type/attribute set.

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
