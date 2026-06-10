# Backend Split

The `eta_sql_driver` tests exercise Eta-owned leased-blocking behavior:
rejecting detach-started blocking pools and invoking cancellation hooks on
timed blocking work. The Eio runtime provides the Eta blocking runtime service,
so these tests are instantiated through `sql_driver_common_suites.ml` for that
backend.

This package has no remaining raw-backend-specific tests.
