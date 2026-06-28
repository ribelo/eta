# PPX Common Backend Split

`test/ppx_common` owns PPX-generated Eta runtime behavior and runs it through
the Eio-backed runtime:

- `[%eta.fn ...]` creates a named span with source location metadata.
- `[%eta.sync ...]` creates a leaf span under the generated function span.

`[%eta.sql.table]` is also covered in `test/ppx_common`. The generator emits
code against `Eta_sql`, so the shared suite links that package even though the
assertions exercise only generated SQL metadata and do not open SQLite or run
database effects. There is no direct `test/ppx` suite.
