# Current Eta Crux delivery baseline

Type: research
Status: resolved
Blocked by: none

## Question

What do current Eta Crux code, laws, tests, and prior decisions require for
commit publication, delivery, acknowledgment, pull observation, and serialized
session replacement?

Reconcile current source with the reports under
`.scratch/research/eta-crux-capability-audit/` and
`docs/wayfinder/eta-crux-capability-audit/`.

Record the exact ownership seams, ordering fences, failure outcomes, capacity
bounds, test controls, wire frames, and performance gates that constrain this
effort. Identify stale claims and missing gates.

## Answer

The current baseline uses complete-output delivery. The
[research report](../../../../.scratch/research/eta-crux-typed-projection-delivery/current-eta-crux-delivery-baseline.md)
records the full evidence and exact source spans.

- One accepted advancement atomically publishes one complete root frame.
- The driver stores the latest committed output before it exposes delivery.
- Identity delivery uses one typed token. Serialized delivery uses
  `Output_deliver` and `Output_result`.
- Successful acknowledgment starts the mandatory post-commit token. Failed
  delivery latches `Adapter_delivery` and does not roll back the commit.
- `Driver.latest_committed_output` is the production pull boundary. Adapters own
  successful-delivery retention and host reconciliation.
- `Serialized_session.replace` closes the old session. It installs a fresh
  registry and redelivers the current output before new advancement.

Eta Crux owns commit, order, acknowledgment, and serialized-session fences. The
driver remains the only transport writer. Current code does not select the
typed-projection interface.

Prior audit claims about missing graph time, missing production pull, and older
session-replacement signatures are stale.

The current executable surface has three coverage gaps:

1. `D-07` lacks required pull observations after failed delivery, stop, and
   crash.
2. The five `Serialized_session.replace_error` outcomes lack dedicated named
   coverage.
3. `W-08` lacks a named observation of the old-session permit wait.

[Session replacement and bootstrap](11-session-replacement-and-bootstrap.md)
already owns the replacement question. [Laws and deterministic test
controls](12-laws-and-deterministic-test-controls.md) already owns the gate
gaps. No new ticket is necessary.
