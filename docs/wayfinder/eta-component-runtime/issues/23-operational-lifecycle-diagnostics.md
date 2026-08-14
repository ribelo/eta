# Operational lifecycle diagnostics

Type: prototype
Status: claimed
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

## Prototype for review

The comparison prototype is on branch
`prototype/eta-component-operational-diagnostics` at commit `da579616`. See the
[prototype source](https://github.com/ribelo/eta/tree/da579616c7284cbe870b4ecceeeb8b9d356878fe/.scratch/eta-component-runtime-operational-diagnostics).

The prototype compares an atomic snapshot, a bounded event journal, and a
terminal settlement report. Its current recommendation selects a snapshot,
coalesced change waits, and context-owned settlement reports.
