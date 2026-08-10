# Ingress admission classes

Type: grilling
Status: open
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does bounded Eta Crux ingress need explicit admission classes or isolation?

Check starvation and terminal-message loss across owner-domain sends, foreign
nonblocking sends, exported endpoints, and request resolution. Compare:

- root-wide FIFO admission.
- per-endpoint capacity.
- reserved guaranteed capacity.
- dropping or sliding admission.
- coalescing by endpoint.

Decide which policies Eta Crux can promise without inferring application
importance. Decide whether to adopt, defer with a precise condition, or reject
each policy.

For each accepted policy, specify its API shape, capacity accounting, ordering,
fairness, failure behavior, laws, test controls, transport equivalence, and
migration effects.
