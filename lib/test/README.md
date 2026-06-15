# eta_test

eta_test provides small testing helpers for Eta programs.

## Package boundary

- `eta_test` depends on `eta`, `eta_eio`, `eio`, `eio_main`, and `alcotest`.
- It is test-only: do not link it into production binaries.
- It pulls `eta_eio` so tests can build a runtime without adding another
  package.

## Scope

The v1 surface contains:

- Test_clock, a virtual-time clock for runtimes created with
  `Eta_eio.Runtime.create ~sleep`.
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

```sh
nix develop -c dune runtest test/test --force
```

`lib/test` is the library; runnable tests live in `test/test`.

Run the full gate with:

```sh
nix develop -c dune runtest --force
```

Without Nix, after `opam install . --deps-only --with-test`, use `dune runtest test/test --force`.
