# Legacy Use Case Simulations

The blocking research uses three representative legacy synchronous workloads:

- DB query: short latency-sensitive sleeps (`db.query` labels).
- Filesystem scan: many slower blocking sleeps (`fs.scan` labels).
- SDK call: labeled legacy calls in the observability probe (`aws-sdk.put`).

The concrete probes live in `resource_classes/`, `bounded_pool/`, and
`api_ergonomics/observability/` so they can share the same measured pool.
