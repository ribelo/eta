# Backend Split

`test/connectors` remains a native integration suite. It exercises DuckDB,
Turso, and Ladybug connector packages, each of which loads external native
driver libraries and validates connector-specific result decoding, prepared
statement cleanup, extension loading, timeouts, and handle ownership.

These scenarios depend on provider C libraries, process environment, and native
driver behavior rather than only the Eta runtime contract. Portable connector
request/codegen helpers should be split separately if they are introduced, but
the current scenarios stay integration-specific.
