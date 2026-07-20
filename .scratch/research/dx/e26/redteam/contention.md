# Red team: `map_par` contention

## Attack

Pull 10,000 values through a tight bounded concurrent map:

```ocaml
List.init 10_000 Fun.id
|> Eta.Effect.map_par ~max_concurrent:64 (fun _ -> Eta.Effect.fresh ())
```

The executable fixture is `test_fresh_map_par_contention` in
`test/test/test_eta_test.ml`. It checks both the output count and
`List.sort_uniq` count.

Command:

```sh
nix develop -c dune exec test/test/test_eta_test.exe -- test Fresh -v
```

Observed on Linux 7.1.3 x86_64:

```text
fresh map_par: n=10000 max_concurrent=64 unique=10000 elapsed_ms=0.958
```

This is a local directional measurement, not a performance guarantee. The
diagnostic fact is `unique=10000`: contention did not produce a duplicate. The
native implementation uses `Atomic.fetch_and_add`; the jsoo implementation uses
a runtime-local mutable cell on its single-domain event loop.
