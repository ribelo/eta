# Backend Split

`test/turso_race` remains a native mock-library race test. It sets
`ETA_TURSO_LIBRARY`, loads `turso_mock_lib.c`, and checks that closing a Turso
connection does not destroy the native database while a step is active.

This is C-stub/native-handle race coverage, not Eta runtime behavior, so it is
not a candidate for backend functorization.
