# DX-E39 Executor Journal — Sealed Predictions

Sealed before consumer/dependency census, benchmark implementation, or any
interpreter/API change. This file is immutable after its first commit.

## Predicted endpoint winner

**Endpoint S (slim).** I predict the evidence will justify deleting static
capability auditing and its assertion vocabulary while retaining `describe` and
`collect_names` as honest, deterministic inspection of the already-constructed
blueprint. The structural need is teaching/debug visibility of a blueprint value,
not runtime capability assurance. I predict Endpoint R will remove useful honest
surface without unlocking a proportional representation saving unless static
`names` propagation proves wholly unrelated to tracing and unusually costly.

## Predicted construction cost

- Removing capability footprints: **10–25% fewer allocated words** for the
  pre-registered construction-heavy map/bind/preserve workload.
- Wall-clock construction time: **5–15% faster**, with more run-to-run noise than
  allocation counts.
- I predict allocated words will meet the assignment's 10% first-class threshold;
  elapsed time may or may not meet it.

These brackets concern blueprint construction only, master versus S, on the same
machine and benchmark corpus. They are not predictions about interpretation.

## Predicted consumer classifications

### `Effect.audit`

- Self-tests/property tests: present and dominant.
- Boundary checks: present through `eta_test`, including the named
  `blocking_common` check.
- Documentation/research references: present.
- Real production/runtime consumer: **none expected**.

### `Effect.describe`

- Snapshot/self-tests: present.
- Documentation/teaching references or tooling: present; this is the expected
  structural need.
- Boundary checks: none expected.
- Real production/runtime consumer: **none expected**, but at least one honest
  teaching/debug consumer is expected and should not be dismissed as mere
  in-repo frequency.

### `Effect.collect_names`

- Self-tests and documentation references: present.
- Internal support for `audit`/introspection: present.
- Boundary checks: none expected.
- Real production/runtime consumer: **none expected**.

### `Eta_test` audit assertions

- Self-tests: present.
- Boundary checks: at least `blocking_common` is expected.
- Documentation references: present.
- Real application behavior checks: **none expected**; any non-self-test use is
  predicted to rely on the static-spine hedge rather than provide a runtime
  guarantee.

## Predicted dependency fault line

I predict runtime tracing is implemented by the evaluator attached to `named`,
not by reading the static `names : string list` carried by `Custom`. Therefore
`leaf_name`/the named evaluator must remain for tracing and `describe`, while the
aggregated `names` field will prove introspection-only. If source evidence instead
shows runtime tracing reads propagated `names`, the objective requires a stop.
