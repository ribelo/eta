# eta_test scope and real I/O

Type: grilling
Status: open
Blocked by:

## Question

Is `eta_test` deliberately deterministic-only, or does it gain real
environment access?

The evidence: zero of six consumers use it. `Run.run` and `with_test_clock`
give no access to a real `env`, `sw`, or net. Tests that need real I/O
cannot use it: pie socket tests, nema LadybugDB tests, and inn server tests.
Consumers re-implement `run_ok` helpers instead.

Decide:

- Deterministic-only: say so in the `.mli`, document the real-I/O recipe,
  and stop implying that `eta_test` serves those tests.
- Or real access: decide the shape, for example passing a real `env` and
  `sw`, and decide the package home.

Either way, decide what happens to the consumer-reinvented `run_ok` helpers.
