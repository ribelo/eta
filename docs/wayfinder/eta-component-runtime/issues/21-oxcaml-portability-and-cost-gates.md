# OxCaml portability and cost gates

Type: prototype
Status: claimed
Blocked by: 06, 15, 18

## Question

Which OxCaml mechanisms improve the selected design, and what portability and
cost gates prevent accidental regressions?

Probe context access, typed-key lookup, inverse registration, notification, and
component-state transitions. Check domain portability, capsule compatibility,
allocation, stack eligibility, and zero-allocation opportunities where the
selected interface permits them.

Optimization cannot change the semantic contract. Record quantitative gates
only after the baseline exists.
