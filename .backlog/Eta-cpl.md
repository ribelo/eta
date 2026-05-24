---
id: Eta-cpl
title: "P2: Retry runner must honor Retry_with_new_connection or remove the variant"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-24T09:06:59.561Z
created_by: backlog
updated_at: 2026-05-24T10:58:58.715Z
close_reason: "Chose fix A: removed Retry_with_new_connection from the generic retry policy API because Retry.run has no transport/pool signal to honor it. Added a RED classification test for Connection_closed, then collapsed it to ordinary Retry_after. Verified with nix develop -c dune runtest packages/eta-http/test --force and nix develop -c dune runtest --force."
---

# P2: Retry runner must honor Retry_with_new_connection or remove the variant

## description

Bug: packages/eta-http/client/retry.ml decision_delay (line 145) collapses Retry_after delay and Retry_with_new_connection delay into Some delay. Retry.run (line ~160) only delays and re-calls request_once with no signal to drop the connection. The variant is exposed in retry.mli but the runner ignores the connection-level distinction — a misleading API.

Location: packages/eta-http/client/retry.ml decision_delay, run, classify_error

## design

RED test (write first):
1. Build a request_once callback that records each connection it receives in a ref counter.
2. Configure the policy so a Connection_closed error on attempt 1 produces Retry_with_new_connection.
3. Trigger that error; let the runner retry.
4. Assert attempt 2 receives a different connection than attempt 1. Currently the runner provides no signal and request_once cannot tell the two retry kinds apart.

Fix shape (pick one and document the choice in the journal):
A) Remove Retry_with_new_connection from this generic policy layer; defer connection-level retries to a transport-aware retry runner. retry.mli loses the variant.
B) Change Retry.run callback signature to request_once : ?force_new_connection:bool -> request -> response Effect.t. Plumb the boolean through decision_delay (which becomes decision_delay : decision -> (Duration.t * bool) option). Pool callers honor the flag and discard a connection from the pool before retry.

## acceptance criteria

RED test fails on current code and passes after the chosen fix. Choice A: retry.mli no longer exposes Retry_with_new_connection. Choice B: pool-aware request_once observably discards the closed connection before retry.
