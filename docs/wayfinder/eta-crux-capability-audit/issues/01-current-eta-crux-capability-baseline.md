# Current Eta Crux capability baseline

Type: research
Status: open

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
