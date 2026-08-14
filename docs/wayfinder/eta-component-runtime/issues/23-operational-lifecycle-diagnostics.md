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
`prototype/eta-component-operational-diagnostics` at commit `f5744913`. See the
[prototype source](https://github.com/ribelo/eta/tree/f574491301cb455b1481a41a1dd247c5c3665910/.scratch/eta-component-runtime-operational-diagnostics).

The corrected prototype compares an atomic snapshot, a typed bounded journal,
and operation settlement reports. It uses complete `Eta.Cause` values.

An independent high-tier review checked Cordis commit
`8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4` and the resolved Eta decisions. The
final verdict was `ready for human validation`.

The provisional recommendation selects snapshots, coalesced change waits,
context-owned settlement reports, and loader-owned pre-admission reports.
