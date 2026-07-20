# Red team: cross-runtime collision

## Attack

Treat `Effect.fresh` as a globally unique identifier source. Run the same
three-pull program against two runtimes freshly created by `Eta_test`.

The regression fixture is `test_fresh_replays_across_test_runtimes` in
`test/test/test_eta_test.ml`. Its observed values are:

```text
runtime A: [1; 2; 3]
runtime B: [1; 2; 3]
collision: 1 = 1
```

Command:

```sh
nix develop -c dune exec test/test/test_eta_test.exe -- test Fresh -v
```

Result: PASS. The collision is intentional and makes the boundary executable,
not hypothetical.

## Did the interface warn the caller?

Yes. `lib/eta/effect.mli` says values are unique and strictly increasing only
within one runtime, explicitly says distinct runtimes/domains may repeat values,
and tells callers to add an application-owned namespace for cross-runtime
correlation. `lib/eta/runtime_contract.mli` repeats the backend obligation.

Verdict: the trap exists, the behavior matches the contract, and the public
interface disarms it without claiming global uniqueness.
