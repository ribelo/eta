# Operational lifecycle diagnostics

Type: prototype
Status: open
Blocked by: 12, 13, 14, 15, 16, 17

## Question

Which immutable observation and diagnostics interface exposes component-context
health, instance phase, desired-state identity, provider episodes, settlement,
and retained causes?

Compare pull snapshots, event streams, and settlement reports. Define identity,
ordering, stale-observation, and cause-rendering rules. Separate application
observations from logs, metrics, and traces.

The interface must represent degraded contexts and quarantined instances. It
must not expose mutable instance handles or erase typed Eta causes.
