# Current Eta Crux capability baseline

Type: research
Status: resolved

## Question

What capabilities and exclusions does the current Eta Crux implementation
actually expose?

Check `lib/crux/eta_crux.mli`, `lib/crux_test/eta_crux_test.mli`, their
implementations, the V1 design documents, semantic laws, verification gates, and
the README exclusion list.

For each of the nine reported gaps:

- state whether the factual claim is correct.
- cite the exact public API, implementation path, law, test, or exclusion.
- classify the current state as missing, partial, application-composable,
  deliberately excluded, or incorrect.
- identify contradictions between code, documentation, laws, and tests.

Also inventory current Eta Crux capability families that the review did not
mention. Record facts only. Do not decide whether Eta Crux must add a capability.

Write one cited report under
`.scratch/research/eta-crux-capability-audit/` and link it from the answer.

## Answer

The [baseline report](../../../../.scratch/research/eta-crux-capability-audit/01-current-eta-crux-capability-baseline.md)
records all nine reported claims as correct:

- Graph time and deterministic clock control are `missing`.
- External graph input is `application-composable`.
- Startup facts and flags are `application-composable`.
- Staged-effect observation is `partial`.
- Host-owned streaming operations are `deliberately excluded`.
- Ingress admission classes are `partial`.
- Pull observation of root output is `partial`.
- Host-operation layers are `application-composable`.
- Action history and diagnostics are `deliberately excluded`.

No claim is `incorrect`. The report also inventories the current production and
test capability families.

The current API, laws, and executable gates agree on these classifications. One
stale first-principles ticket names `Driver.replace_serialized_session`, but the
current API exposes `Serialized_session.replace`.

The private driver caches committed output before delivery. The test handle
caches output only after successful delivery. These states have different
observation boundaries.
