# Action history and diagnostics

Type: grilling
Status: open
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does Eta Crux need bounded action history or stronger diagnostics?

Check the existing telemetry and failure-snapshot contracts. Separate bounded
committed-action diagnostics from replay, time travel, graph inspection, and
application-owned domain history.

Decide whether to adopt, defer with a precise condition, or reject each
diagnostic capability. If bounded history is adopted, specify enablement,
capacity, identity, redaction, retention, crash-report integration, ordering,
runtime cost, API shape, laws, test controls, ownership, and migration effects.
