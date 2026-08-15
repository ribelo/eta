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

## Prototype for review

The comparison prototype is on branch
`prototype/eta-component-oxcaml-cost-gates` at commit `65d0c627`. See the
[prototype source](https://github.com/ribelo/eta/tree/65d0c6273a736e6a1cd472f7011ff738e03f9ae0/.scratch/eta-component-runtime-oxcaml-cost-gates)
and its
[findings](https://github.com/ribelo/eta/blob/65d0c6273a736e6a1cd472f7011ff738e03f9ae0/.scratch/eta-component-runtime-oxcaml-cost-gates/FINDINGS.md).

The compiler probes cover portability, contention, abstraction, local escape,
capsule access, and zero-allocation helpers. The runtime probe records one
allocation baseline for the five named operations.

The provisional recommendation keeps lifecycle authorities owner-domain and
abstract. It uses private zero-allocation checks and package benchmarks. It does
not add public modes, capsules, or unboxed types.

An independent high-tier review found no remaining material fault. Its final
verdict was `ready for human review`.
