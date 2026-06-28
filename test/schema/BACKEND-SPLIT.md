# Backend Split

The former direct `test/schema/run.ml` executable has been moved into
`test/schema_common` and is now instantiated by `test/schema_eio`.

These scenarios cover Eta-owned schema and JSON behavior, including typed
decode/encode failures and `decode_with_policy` effects. `Eta_schema_test` now
evaluates effects through an explicit backend runner, so helper coverage is also
kept behind a backend runner instead of living in a direct package-local test.
