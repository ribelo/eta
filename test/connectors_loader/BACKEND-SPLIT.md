# Backend Split

`test/connectors_loader` remains native-loader-specific. It builds fake shared
libraries, sets `LD_LIBRARY_PATH`, and verifies dynamic loader fallback, symbol
ownership, native pointer lifetime, and GC-root behavior for DuckDB, Turso, and
Ladybug bindings.

Those checks are C-stub and process-loader integration tests, not Eta runtime
behavior, so they are not candidates for backend functorization.
