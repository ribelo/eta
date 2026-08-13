# Commit observation and ownership contract

Type: grilling
Status: open
Blocked by: 08

## Question

What observation and ownership contract must any selected interface satisfy?

Decide initialization, significant change, dynamic removal, commit-level
batching, and the relationship with complete root-output delivery.

Define latest committed and latest delivered observations. Decide which module
retains each value and when acknowledgment admits post-commit work.

Specify the atomic observation boundary for one commit. Include delivery failure
and commits with no changed values.
