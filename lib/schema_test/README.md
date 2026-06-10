# eta-schema-test

eta-schema-test provides Alcotest helpers for Eta Eta_schema tests.

The v1 surface covers deterministic examples:

- schema JSON, issue, and issue-list testables
- decode and encode success helpers
- decode and encode failure extraction
- JSON round-trip checks
- a small evaluator for the pure Eta effect subset emitted by Eta Eta_schema,
  run through an explicit Eta backend runner

Property-based generators and arbitrary derivation are deliberately out of
scope for v1.
