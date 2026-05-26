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
| C. PPX-generated request modules | Can validate SQL literals and generate bind/decode boilerplate. | Adds generated code and still cannot improve host-language composability for this slice. | Deferred / untested |

## Proof Ladder

1. P0: runnable positive fixture for A, B, and generated-request shape.
2. P1: package API supports SELECT/INSERT/UPDATE/DELETE.
3. P2: typed nullable/bool row decoding and prepared parameter binding.
4. P3: negative/error behavior: invalid query, many rows for find_opt.
5. P4: typed compiled query execution through `Sql.Eta_pool`.
6. P5: production SQL surface: aggregates, GROUP BY/HAVING, DISTINCT,
   subqueries, CTEs, UPSERT, RETURNING, and window functions.
7. P6: release build and package tests.

Current P5 status: DISTINCT, COUNT, SUM, GROUP BY, HAVING, subquery
predicates, CTEs, UPSERT/ON CONFLICT, RETURNING, and ROW_NUMBER window
projection have fixture or package-test coverage.
