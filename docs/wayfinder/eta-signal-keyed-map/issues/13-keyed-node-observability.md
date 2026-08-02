# Keyed node observability

Type: grilling
Status: claimed
Blocked by: 07, 08

## Question

What minimum diagnostics make keyed reconciliation visible through existing Eta
Signal observability without publishing another expert surface?

Decide which existing stats and DOT views include keyed nodes, scopes, and
structural transitions. Define the counters needed to distinguish full map
scans from changed-key work.

Specify visibility for provisional additions, rolled-back edits, invalidated
scopes, and committed children. Diagnostics must not retain live child state or
change transaction behavior.

Name the tests that prove counter and graph-view behavior. Do not add logging,
action history, or time travel to this package.
