# Effect provide Survival Lab

This lab now builds the post-deletion shape for the Effet-0u8 survival result.
The historical with-provide candidates were removed with the public API; their
compiler output and LOC comparison are recorded in journal.md.

The remaining modules prove the ordinary OCaml replacement across three
fixtures:

- scoped service factory;
- test-local mock injection;
- sandboxed subsystem with fewer capabilities than the parent.

Run:

    nix develop -c dune build scratch/provide_survival
    nix develop -c dune exec scratch/provide_survival/runtime_smoke.exe

The smoke runner asserts the expected behaviour without any Effect.provide
dependency.

neg_without_provide_missing_arg.ml remains as the post-deletion negative probe:
adding it to the executable modules must fail because a service-parameterized
child function is not an already-built effect.
