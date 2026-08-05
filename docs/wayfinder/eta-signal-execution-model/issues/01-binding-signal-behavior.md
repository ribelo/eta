# Binding Signal behavior

Type: task
Status: resolved

## Question

Which exact executable laws, tests, interfaces, and prose define the binding
Signal behavior contract?

Separate observable behavior from assumptions about transactions, phases,
lanes, schedulers, topology storage, and module ownership. Record each behavior
with its observation point and authoritative source.

## Answer

The binding oracle contains 20 scalar Signal rows and 12 Signal Map rows.
Public values, failures, callbacks, lifecycle events, compile-time fences,
diagnostics, and affected-work bounds remain binding.

Private phases, transactions, queues, topology storage, lane records, timer
records, map trees, and module seams reopen. Private tests supply scenarios
rather than mandatory representations.

The complete census is in
[Binding Signal behavior](../../../../.scratch/research/eta-signal-execution-model/binding-signal-behavior.md).
