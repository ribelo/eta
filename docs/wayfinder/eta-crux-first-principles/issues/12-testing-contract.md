# Deterministic testing contract

Type: grilling
Status: open
Blocked by: 04, 06, 07, 08, 09, 11, 18

## Question

What test surface follows naturally from typed computations and deterministic
advancement, without creating a second runtime semantics?

Decide how tests:

- construct a root with inputs and dependencies.
- inject typed actions and advance one transaction.
- inspect typed root output and observation-plan delivery.
- intercept, execute, cancel, or provide results for staged Eta effects.
- control time and long-lived sources.
- assert dynamic activation, disposal, keyed identity, and stale injection.
- assert typed failures, defects, and cleanup causes.
- arbitrate ingress closure against endpoint admission.
- arbitrate commit against fatal detection and batch start against stop.
- inspect primary failures, ordered secondary records, and final settlement.
- request exhaustive checks without depending on internal node structure.
- test a host adapter through a recording fake.

The test package must use the production advancement primitive. It must not
identify effects by anonymous function identity or duplicate the Eta runtime.
