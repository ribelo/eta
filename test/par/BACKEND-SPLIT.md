# Backend Split

`test/par_common` owns pure `Eta_par` scheduler and parallel-iterator
correctness tests. The suite does not depend on Eta runtime primitives, but it is
still instantiated under `test/par_eio` so package-level
coverage follows the native backend matrix.

`test/par` now remains the Eio-specific island integration suite. Those tests
create `Eta_eio.Runtime`, use Eio switches/backends, and exercise
`Eta_par.Island` through Eta effects, so they should not be claimed as
backend-neutral until island execution has a first-class backend-neutral runtime contract.
