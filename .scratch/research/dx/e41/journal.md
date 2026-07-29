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

## Follow-ups — optional-argument erasure and final contract

This section is appended under follow-up authority; the sealed prediction text
above remains byte-for-byte unchanged.

Follow-up 1 first preferred deleting `?random`, because no caller supplied it
and E19 already provided scoped `Effect.with_random`. That change exposed a
second wart rather than completing the regression. OxCaml rejected the required
partial callback form

```ocaml
let@ refreshable = Refreshable.with_auto ~load ~schedule in
body refreshable
```

with this diagnostic:

```text
This expression has type
  ?on_error:('a -> unit) ->
  ((int, 'a) Refreshable.t -> ('b, 'a) Effect.t) -> ('b, 'a) Effect.t
but an expression was expected of type ('c -> 'd) -> 'e
Hint: This function application is partial, maybe some arguments are missing.
```

The established erasure rule is: an optional argument erases when a following
positional argument is applied, when the call is fully applied, or when a fully
pinned expected type supplies enough information. Applying later labeled
arguments (`~load`, `~schedule`) does **not** erase it, and `ppx_let`/`let@` does
not propagate its expected callback type early enough. The earlier apparent
success of `?on_error` was not evidence: those call sites explicitly supplied
`~on_error`. Therefore no optional argument can precede the callback in this
signature.

Follow-up 2 supersedes Follow-up 1 with two zero-optional public functions:
canonical `with_auto ~load ~schedule body`, and the rare explicit
`with_auto_on_refresh_error ~on_refresh_error ~load ~schedule body`. Both
delegate to one private helper taking an explicit callback option. The split
preserves immediate typed-refresh alerting without imposing placeholder syntax
on canonical `let@` use. The cache census is consequently **14 public vals**,
`+6` from the baseline of 8 rather than the sealed `+5` prediction.

### Scoped-random reach verdict: reached

The original direct `Schedule.start ?random` in `eta_cache` could use its own
default or an explicit token but could not resolve the runtime's fiber-local
override. No new core leaf is needed: public `Effect.repeat` resolves
`Runtime_core.current_random` at interpretation time and passes it explicitly to
`Schedule.start` (`lib/eta/effect_schedule.ml:8-15`). `Refreshable` now runs a
private initial no-op iteration followed by refresh iterations through
`Effect.repeat`; this preserves the prior schedule-before-first-refresh timing
while reaching both the runtime default and inherited `Effect.with_random`
binding.

`Refreshable with_auto uses scoped or runtime random` compares the exact two-draw
jitter sequence against `Schedule.start` with the runtime seed, then replays one
scoped seed across runtimes with different defaults. The native parity test and
the js_of_ocaml facade test also compile and run both zero-optional `let@` forms
and their direct-call forms.

## Follow-up 3 — independent-review score

**Score: 4 justified findings, 0 unjustified.** The review correctly upheld the
implementation while rejecting evidence and prose that were not precise enough
to support the handoff.

1. **F1 justified — material test-design miss.** The sealed prediction named
   post-scope observations and warned that merely seeing body exit was
   insufficient, but the delivered matrix used `Schedule.recurs 1`. After the
   blocked second load was cancelled, natural exhaustion made the exact count
   and empty census non-discriminating. The prediction should have required an
   unbounded schedule or a remaining recurrence plus a post-exit third-load trap.
   All four exit tests now use an unbounded spaced schedule, advance the test
   clock one hour after the outer exit, and assert an exact two calls. The census
   test performs the same post-scope advance before taking its empty-fiber
   snapshot. These new tests passed against the unchanged implementation, so the
   hole was evidence-only, not a runtime defect.
2. **F2 justified.** Both OTel documents falsely described configuration through
   the old `Resource` API before this branch. Renaming that false statement to
   `Refreshable` preserved rather than repaired it. The branch owns that miss.
   The docs now match `Eta_otel.create`: it assembles one immutable configuration
   record on the exporter handle, and daemons read it directly; `eta_otel` has no
   cache dependency or ambient configuration channel.
3. **F3 justified.** R167's loader returned the same value on duplicate seed
   calls, and R175 observed only the final ledger. The manual test now asserts an
   exact one-call seed boundary. A new promise barrier blocks inside
   `on_refresh_error` while the body reads `failures`, proving the typed failure
   is already recorded. The removed-claim disposition now includes R176.
4. **F4 justified.** Merely defining the canonical example before the alerting
   helper was not executable evidence when `main` ran only the rare helper. The
   executable now runs `with_auto` and prints `cached-resource:canonical`; the DX
   guide now says “lexically owned refreshable failure diagnostics.”
