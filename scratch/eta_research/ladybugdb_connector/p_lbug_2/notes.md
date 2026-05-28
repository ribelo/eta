# P-Lbug-2 - Cancellation Under Effect.timeout

Status: Confirmed
Verdict: Confirmed - wrapping a long-running LadybugDB query in Effect.blocking with on_cancel=lbug_connection_interrupt and Effect.timeout returns Timeout and leaves the connection reusable.

## Command

Captured log:

scratch/eta_research/ladybugdb_connector/p_lbug_2/p_lbug_2.log

Command used:

nix develop -c env LD_LIBRARY_PATH=/tmp/ladybug/build/src dune exec scratch/eta_research/ladybugdb_connector/p_lbug_2/p_lbug_2_probe.exe

The log was captured with stdout/stderr redirected to p_lbug_2.log.

## What Was Tested

- Created an in-memory LadybugDB database.
- Created 20,000 N nodes.
- Ran a deliberately expensive Cypher query through Effect.blocking:
  MATCH (a:N), (b:N), (c:N) RETURN sum(a.id + b.id + c.id)
- Attached on_cancel to lbug_connection_interrupt.
- Wrapped the blocking query in Effect.timeout (Duration.ms 200).
- Verified the same connection can execute RETURN 1 after timeout.

## Evidence

Relevant lines from p_lbug_2.log:

    timeout_ms=200
    elapsed_ms=200.338
    on_cancel_calls=1
    effect_result=Error:Timeout
    connection_reusable=true
    verdict=Confirmed

## Surprise Findings

- A CROSS-product count query completed in about 9 ms and was not a valid cancellation fixture; LadybugDB can optimize that shape away.
- When the C binding raised on non-success after interrupt, Eta reported Concurrent[Die(...); Fail(Timeout)]. The production binding should map the interrupted query return path to a controlled error value instead of raising a defect after timeout cancellation.

## What Was Not Measured

- No repeated cancellation loop.
- No interrupt latency distribution beyond the single timeout run.
- No cooperative cancellation fallback, because an interrupt API exists and worked.
- No prepared-statement cancellation.

## Stop/Continue Decision

P-Lbug-2 does not trigger the hard stop. Continue to P-Lbug-3.
