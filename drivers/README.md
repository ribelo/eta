# Eta Drivers

`drivers/` is reserved for optional integration packages that bind Eta-owned
protocols to concrete external engines or services.

Keep drivers outside `lib/` unless they are promoted into Eta's core library
surface. A driver may depend on Eta libraries, third-party client libraries, and
engine-specific system packages; core Eta libraries must not depend on drivers.

Use engine-specific subdirectories when the external dependency is concrete, for
example `drivers/duckdb/` or `drivers/postgres/`. Use a capability or protocol
name only when the driver is genuinely engine-generic.

Driver packages should make ownership clear:

- applications own state, credentials, connection strings, and lifecycle policy;
- Eta owns effect description, typed failures, resource cleanup, and runtime
  observability;
- drivers translate between those boundaries without adding application
  framework behavior.

Do not add compatibility shims for old driver paths. Rename or delete stale
paths and update callers in the same change.
