# DX-E24b follow-up reviewer questions

Read `DECISION.md` and `DELETION_PROPOSAL.md`, then inspect `../journal.md` and
`../redteam/` only as needed.

1. Does candidate D's asserted surface include every producer, interpreter,
   signature, documented promise, re-export, and no-hook consequence?
2. Is the ordinary operation-level recipe rated fairly for Effect, Resource,
   Stream, and custom drivers, including the exact structural capability it
   cannot replace?
3. Does zero non-test production/example demand justify the deletion proposal,
   or is there a concrete current demand signal the packet missed?
4. Is every suspension/observability matrix cell supported, especially multiple
   resume, partial effects/retry, cancellation, wrapper order, and telemetry?
5. Does `schedule.mli` place every obligation on the correct owner and distinguish
   `tap_input` from `tap_output` failure precisely?
6. Are M97–M112/R102 one-claim registrations with valid named coverage and exact
   source spans?
7. Are B and C now narrowed correctly: only top-level B loses structural parity,
   and only the tested C variants fail or add surface?
8. Is accepting D as a separate deletion proposal consistent with leaving the
   current runtime unchanged in this follow-up?
