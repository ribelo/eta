# Backend Split

`test/sql_common` covers the backend-neutral SQL DSL/rendering contract through
`eta_sql_dsl` and is instantiated by `test/sql_eio`. This
includes pure query rendering, schema rendering, row/value helpers, and source
invariants for the DSL builder implementation. These tests intentionally avoid
the native `eta_sql` SQLite package so pure query-builder behavior does not
inherit an Eio/SQLite dependency for pure query-builder behavior.

`test/sql_driver` covers the backend-neutral SQL-driver blocking contract for
the Eio backend.

The remaining `test/sql` suite is native-specific. It exercises the `eta_sql`
SQLite C stubs, SQLite file paths, migration source files and symlinks, native
timeout/interrupt behavior, pool behavior, and source-file invariants for
connector implementations. Those cases should stay explicitly registered there
unless a real backend-neutral SQL execution surface is introduced.
