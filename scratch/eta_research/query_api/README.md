# SQL Query API Lab

This lab decides the first Drizzle-like OCaml query authoring API for the
eta-sql package on top of its Sqlite connector.

## Decision Question

What API should eta-sql expose for writing SQLite queries idiomatically in OCaml
without becoming an ORM?

The selected API must:

- use ordinary OCaml values/modules as the authoring surface;
- support schema and column descriptors;
- support SELECT, INSERT, UPDATE, and DELETE;
- bind values through prepared SQLite statements rather than string
  interpolation;
- decode typed rows without a universal row map;
- execute typed queries through `Sql.Eta_pool`, not only synchronous `Sqlite.db`;
- reject wrong-table column composition through the type system where the host
  language can do so;
- decide whether PPX is required for this first slice.

## Candidates

| Candidate | Steelman | Falsifier | Status |
| --- | --- | --- | --- |
| A. Generative table modules + typed builder | Drizzle-like enough while staying idiomatic OCaml; table phantom types reject wrong-table composition; no PPX build cost. | Cannot express core CRUD ergonomically, or call sites become noisier than raw SQL. | Selected |
| B. Raw typed request records | Minimal, explicit, fast to implement, and close to Caqti's proven request separation. | Manual SQL/bind/decode duplication dominates normal use. | Baseline |
| C. Builder-generation PPX | Can generate request modules around selected builder/raw query shapes. | Adds generated code and still does not improve host-language composability for this slice. | Not selected |
| D. Schema/table PPX | Removes per-table module ceremony while preserving the selected typed builder and Eta_pool execution path. | Generated code fails to preserve phantom-table rejection, records, or schema metadata. | Accepted as optional sugar |
| E. SQL-literal PPX | Can validate SQL literals and generate bind/decode boilerplate for SQL-shaped queries. | Parser/introspection cost outweighs concrete consumer need, or generated types cannot compose with Eta_pool. | Deferred / untested |

## Proof Ladder

1. P0: runnable positive fixture for A, B, and generated-request shape.
2. P1: package API supports SELECT/INSERT/UPDATE/DELETE.
3. P2: typed nullable/bool row decoding and prepared parameter binding.
4. P3: negative/error behavior: invalid query, many rows for find_opt.
5. P4: typed compiled query execution through `Sql.Eta_pool`.
6. P5: production SQL surface: aggregates, GROUP BY/HAVING, DISTINCT,
   subqueries, CTEs, UPSERT, RETURNING, and window functions.
7. P6: release build and package tests.
8. P7: schema/table PPX expands to the same generative table module shape,
   preserves wrong-table rejection, and executes typed records through
   `Sql.Eta_pool`.

Current P5 status: DISTINCT, COUNT, SUM, GROUP BY, HAVING, subquery
predicates, CTEs, UPSERT/ON CONFLICT, RETURNING, and ROW_NUMBER window
projection have fixture or package-test coverage.

Current P7 status: [%%eta.sql.table type users = { ... }] expands to a
users_row record, a Users generative table module, typed columns, Users.all as
an all-column record projection, and Users.schema as a schema artifact. The
positive fixture executes the generated typed record projection through
Sql.Eta_pool; the negative fixture proves generated phantom table types still
reject wrong-table projections.
