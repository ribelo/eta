# Admission/deadlock evidence pair

## Observation boundary and generated class

Both directions use the same barrier shape: `N` children acquire a scoped active
marker, publish admission, sleep for 10 ms, and complete only after all `N`
admissions exist. Finalizers decrement the active count. The generated laws use
`N = 9..12` for `all` and `N = 2..12` with bound `N - 1` for `all_bounded`, so
the distinguishing case is mandatory rather than probabilistic.

Source:

- shared shape: `test/laws/law_properties.ml:775-799`
- positive generated law: `test/laws/law_properties.ml:801-822`
- explicit full-bound migration witness: `test/laws/law_properties.ml:824-832`
- negative generated law: `test/laws/law_properties.ml:834-853`
- shared-runtime shape and pair: `test/core_common/effect_common_suites.ml:2898-2996`

## Positive direction — `all`

`all` admits all `N`; after 10 ms, all children observe all admissions and return
in input order before the 15 ms watchdog. Assertions require exact admitted,
checked, completed, finalized, sleeper, and fiber counts.

## Negative direction — `all_bounded`

`all_bounded ~max_concurrent:(N - 1)` admits exactly `N - 1`; each admitted child
checks once and waits again, no child completes, the final child remains
unadmitted, and the 15 ms watchdog returns `Cause.Fail `Watchdog`. Cancellation
runs all admitted finalizers and leaves empty sleeper and fiber censuses.

## Outputs

- `deadlock-shared-output.txt`: shared Eio suite; the pair and adjacent parity
tests pass.
- `deadlock-law-output.txt`: 50 generated runs for each admission direction,
  bounds, ordering, fail-fast/finalizer parity, construction rejection, and
  `all_settled` shared admission; all 77 law properties pass.

Commands:

```sh
nix develop -c dune runtest test/laws test/core_common --force
nix develop -c dune runtest test/core_eio --force
EIO_BACKEND=posix _build/default/test/core_eio/run.exe test --color=never Effect 140-146
nix develop -c env EIO_BACKEND=posix _build/default/test/laws/law_properties.exe
```
