# DX-E41 executor journal — sealed predictions

Sealed before any source, interface, test, package, or documentation change.
This file is immutable after its first commit. The orchestrator journal was not
read.

## Baseline and predicted census

The census counts public compilation modules and every `val` declaration in
their public interfaces, including values nested in public signatures. The root
count excludes `runtime_supervisor.mli`, the only interface-bearing module in
`lib/eta/dune`'s `private_modules` list.

| surface | before | predicted after | delta |
| --- | ---: | ---: | ---: |
| root `eta` public modules | 29 | 28 | -1 (`Resource`) |
| root `eta` public vals | 490 | 485 | -5 |
| `eta_cache` public compilation/exposed modules | 1 | 2 | +1 (`Refreshable`) |
| `eta_cache` public vals | 8 | 13 | +5 |
| `Eta_js` module aliases | 21 | 21 | 0 (`Resource` renamed to `Refreshable`) |

I expect the value move to be cardinality-neutral across the two packages:
`manual`, `get`, `refresh`, and `failures` move unchanged while `auto` is
replaced one-for-one by `with_auto`. `Eta_cache`'s main interface will gain one
`Refreshable` module alias. `eta_js` will gain a direct `eta_cache` package
dependency; root `eta` will not.

Footgun prediction: **-1/+0 (net -1)**. Removing the collision between cached
values and lexical acquire/release resources removes one mental-model trap. The
lexical callback does not add a new lifetime ambiguity because it makes the
refresh loop's owner syntactically mandatory.

## Expected migration size

The repository call-site census found no production call that needs a
runtime-owned lifetime. The only `auto` consumers are one executable example,
the shared resource test suite, and API-DX executable/snippet fixtures. The
manual form appears in the second example and those same two test surfaces.
`Eta_js` has one alias in each of its implementation and interface.

Predicted direct migration:

- 2 moved/renamed module files plus the 2 `Eta_cache` facade files;
- 2 examples;
- 2 existing test files, with the scope and preservation matrix concentrated in
  the shared suite; focused cache/js build verification may require test Dune
  wiring but no second implementation;
- 2 `Eta_js` facade files;
- 3-5 Dune/package metadata files, including generated `eta_js.opam`;
- the changelog, law registry, and 6-8 direct prose/topology references found by
  the stale-name census (`README`, API-DX/type-error/tutorial docs, OTel README,
  repository guidance, and the backend split note).

I predict 22-30 changed paths and roughly 300-550 non-move line events. The
required exit-kind and preservation tests, rather than the module move, should
dominate additions.

## Predicted scope-exit evidence

I will test `with_auto` as a lexical owner, not infer ownership from a returned
handle:

1. body success cancels and awaits the refresh loop;
2. body typed failure preserves that failure while cancelling and awaiting the
   loop;
3. body defect preserves the defect while cancelling and awaiting the loop;
4. parent cancellation interrupts the body and cancels and awaits the loop;
5. a refresh already blocked at a cancellation checkpoint is interrupted and
   its finalizer completes before `with_auto` exits;
6. an `Eta_test.Run` observation ends with an available empty pending-fiber
   census.

The discriminating markers will be refresh-start, refresh-cancel/finalizer, body
exit, and post-scope observations. Merely seeing the body exit is not evidence
that the child was awaited.

The preservation matrix should additionally prove seed failure suppresses the
body; failed refresh keeps the last good value; `failures` preserves observation
order and distinguishes `Cause.Fail` from `Cause.Die`; an `on_error` exception
adds a later `Die` without stopping refresh; schedule exhaustion stops refresh
while the body and handle remain usable; and a later successful refresh replaces
the stale value.

## Hold-trigger prediction

**None.** The only current `auto` sites are examples and tests whose whole use
already sits inside one interpreted effect. I expect each to become a direct
`with_auto ... (fun refreshable -> ...)` lexical body. If a later audit finds a
real call that returns the handle for runtime-owned refreshing, I will stop and
record its source verbatim rather than retain or emulate `auto`.

## Likeliest review reservations

1. `with_supervised_background` must not accidentally convert a refresh-loop
   cancellation/finalizer failure into a silently detached child. The review
   should demand evidence that cancellation awaits the in-flight refresh and
   that its finalizers have completed on all four body exits.
2. Moving the alias makes `eta_js` depend on optional `eta_cache`, and keeping
   old shared tests under the core test harness can obscure package ownership.
   The review should verify the dependency direction is only
   `eta_cache`/`eta_js` -> `eta`, that root install metadata stays free of cache,
   and that both native and js_of_ocaml cache targets compile the moved module.
