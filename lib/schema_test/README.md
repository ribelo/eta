# eta_schema_test

eta_schema_test provides Alcotest helpers for `eta_schema` tests.

## Package boundary

- `eta_schema_test` depends on `eta`, `eta_schema`, and `alcotest`.
- It is test-only: do not link it into production binaries.

## Scope

The v1 surface covers deterministic examples:

- schema JSON, issue, and issue-list testables
- decode and encode success helpers
- decode and encode failure extraction
- JSON round-trip checks
- a small evaluator for the pure Eta effect subset emitted by `eta_schema`,
  run through an explicit Eta backend runner

Property-based generators and arbitrary derivation are deliberately out of
scope for v1.

## Development

Run the package tests:

```sh
nix develop -c dune runtest test/schema_test_eio --force
```

Run the full gate:

```sh
nix develop -c dune runtest --force
```

Without Nix, after `opam install . --deps-only --with-test`, use `dune runtest test/schema_test_eio --force`.
