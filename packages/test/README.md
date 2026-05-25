# eta-test

eta-test provides small testing helpers for Eta programs.

## Scope

The v1 surface contains:

- Test_clock, a virtual-time clock for runtimes created with Runtime.create
  ~sleep.
- Test_random, deterministic seeded Capabilities.random tokens for scheduler
  and runtime tests.
- Expect, cause-aware Alcotest assertions for Exit.Ok, typed failures,
  defects, and interrupts.
- with_logger, with_tracer, and with_logger_and_tracer helpers for runtimes
  configured with Eta's in-memory observability capabilities.

Test_clock is Eta-shaped: it controls runtime sleeps used by Effect.delay,
Effect.timeout, Effect.repeat, and Effect.retry. It is not an effect-smol
service clone, and it does not replace application-owned state.

Property-based generators are deliberately out of scope for v1 and deferred to
v2.

## Development

Run the package tests with:

    nix develop -c dune runtest packages/eta-test --force

Run the full gate with:

    nix develop -c dune runtest --force
