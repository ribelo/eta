# Staged-effect observability

Type: grilling
Status: open
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

What direct observation of staged transition effects belongs in Eta Crux tests?

Check whether tests can assert ordered staging, absence, start, interruption,
and settlement without waiting for downstream consequences. Compare:

- injected controlled dependencies.
- per-commit effect lifecycle observations.
- Eta-level effect observations.
- an inspectable command algebra.

Opaque Eta effects remain the default. Consider a command algebra only if opaque
effects cannot provide the required assertions without duplicated protocols.

Decide whether to adopt, defer with a precise condition, or reject each needed
observation. For accepted observations, specify identity, ordering, redaction,
API shape, laws, test controls, ownership, runtime cost, and migration effects.
