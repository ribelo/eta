# Admission/deadlock evidence pair

## Observation boundary and generated class

The shared-runtime pair uses the same barrier shape in both directions: `N`
children acquire a scoped active marker, publish admission, sleep for 10 ms, and
complete only after all `N` admissions exist. Finalizers decrement the active
count.

The generated positive law uses a finite cooperative-yield budget instead of a
virtual-time watchdog: under full admission every child completes, while an old
cap-eight engine reaches `Admission_withheld` rather than hanging the suite. The
generated negative law retains the 10 ms polling barrier and 15 ms watchdog.
Generated classes are `N = 9..12` for `all` and `N = 2..12` with bound `N - 1`
for `all_bounded`, so the distinguishing case is mandatory.

Source:

- timed negative shape: `test/laws/law_properties.ml:799-823`
- finite positive shape and generated law: `test/laws/law_properties.ml:825-872`
- explicit full-bound migration witness: `test/laws/law_properties.ml:874-882`
- negative generated law: `test/laws/law_properties.ml:884-903`
- shared-runtime shape and pair: `test/core_common/effect_common_suites.ml:2898-2996`

## Positive direction — `all`

`all` registers all `N`; every generated child observes all admissions within
the finite yield budget and returns in input order. Assertions require exact
admitted, completed, finalized, and fiber counts. The shared-runtime counterpart
still proves the same shape completes after the 10 ms barrier and before its
15 ms watchdog.

## Negative direction — `all_bounded`

`all_bounded ~max_concurrent:(N - 1)` admits exactly `N - 1`; each admitted child
checks once and waits again, no child completes, the final child remains
unadmitted, and the 15 ms watchdog returns `Cause.Fail `Watchdog`. Cancellation
runs all admitted finalizers and leaves empty sleeper and fiber censuses.

## Outputs

- `followup-admission-output.txt`: three counted Eio backend regressions prove
  synchronous-failure registration for `all` and `all_settled`, plus the
  admission-versus-preemption boundary.
- `followup-law-output.txt`: 50 generated runs each for the two registration
  laws and both deadlock directions.
- `deadlock-shared-output.txt`: shared Eio suite; the pair and adjacent parity
tests pass.
- `deadlock-law-output.txt`: 50 generated runs for each admission direction,
  bounds, ordering, fail-fast/finalizer parity, construction rejection, and
  `all_settled` shared admission; all 77 law properties pass.

Commands:

```sh
nix develop -c dune runtest test/laws test/core_common --force
nix develop -c dune runtest test/core_eio --force
EIO_BACKEND=posix _build/default/test/core_eio/run.exe test '^Effect Eio admission$'
nix develop -c env EIO_BACKEND=posix _build/default/test/laws/law_properties.exe
```
