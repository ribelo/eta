# Cause Research Lab

This lab compares the current slim Cause.Both algebra with a structured
algebra that distinguishes sequential failures, concurrent failures, and
finalizer suppression.

Run:

    nix develop -c dune build scratch/cause_research
    nix develop -c dune exec scratch/cause_research/runtime_smoke.exe

The fixture functor in fixture.ml drives both candidates through the same
cases:

- two concurrent failures;
- fail-fast collection plus a sibling finalizer failure;
- nested scoped finalizer failure during body failure;
- sequential rethrow/observer failure;
- catch over a single typed Fail versus a compound cause.

The output is intentionally textual so the journal can quote the information
that each algebra preserves or erases.
