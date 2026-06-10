# Backend Split

`test/duckdb` remains DuckDB-native-specific. It checks DuckDB SQL behavior,
dynamic loader failure paths, appender/row cursor ownership, transaction SQL,
pool shutdown around active native connections, and source-file invariants for
the DuckDB connector implementation.

The suite uses DuckDB C bindings and raw Eio synchronization around active pool
leases, so these tests are connector integration checks rather than portable
Eta runtime behavior.
