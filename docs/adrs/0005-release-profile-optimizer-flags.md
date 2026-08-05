# ADR 0005: Release-profile optimizer flags, and why the Flambda 2 reaper stays off

Status: accepted.

## Context

Eta is closure-heavy. The effect type carries closures in almost every
constructor, and every combinator allocates at least one. So the compiler's
treatment of closures matters more to Eta than to an average OCaml library, and
it is tempting to reach for optimizer flags.

The repository builds on OxCaml `5.2.0+ox`, whose middle end is **Flambda 2**
(`ocamlopt -config` reports `flambda: false`, `flambda2: true`). Until this ADR
the root `dune` release profile passed:

```
-O3 -unbox-closures -unbox-closures-factor 20 -rounds 2
```

Three of those four flags do nothing.

`-unbox-closures`, `-unbox-closures-factor` and `-rounds` are **Flambda 1**
flags. The OCaml manual states that "Flambda-specific flags are silently
accepted even when the `-flambda` option was not provided", with no means to
change that behaviour, so they produced no warning. The Flambda 2 design
presentation lists "unboxing of free variables of functions inside closures" as
*not yet implemented in Flambda 2* - which is exactly what `-unbox-closures`
did in Flambda 1.

This was verified rather than assumed. Building `lib/eta/bench/bench_eta.exe`
under the release profile with and without those three flags produced a
**byte-identical** executable (sha256 `1f5da190...`). As a control, adding
`-flambda2-reaper` changed the hash to `a31d5b34...`, proving the comparison is
sensitive to flags that actually do something.

There is no Flambda 2 "closure folding" flag. The nearest candidate,
`-flambda2-expert-fallback-inlining-heuristic`, controls whether functions whose
bodies contain closures may be inlined, and the permissive setting is already
the default.

Two default-off Flambda 2 flags were measured against the effect-core allocation
benchmark:

- `-flambda2-join-points`: no effect on any allocation row.
- `-flambda2-reaper`: no effect on the effect-core rows, but
  `eta.queue.unbounded.fill_drain` fell from 168 to 147 words per operation
  (-12.5%) and `eta.pool.with_resource.warm` fell by 11 words.

## Decision

The release profile passes `-O3` and nothing else.

`-flambda2-reaper` is **not** enabled, despite its measured win.

## Consequences

The reaper's benefit here is narrow: it moved one benchmark row by 12.5% and
left the effect core unchanged. Weigh that against its maturity on this
compiler.

The reaper is default-off in `5.2.0+ox`. The OxCaml changelog for later versions
records roughly ten reaper crash and correctness fixes - #5129, #5137, #5139,
#5142, #5144, #5145, #5147, #5374, #5377, #5379 - including unboxed-block call
crashes, an over-zealous rebuild check, and "prevention of unboxing the first
parameter of exception handlers". None of those fixes are in the compiler this
repository pins.

That last one is decisive for Eta specifically. Eta routes **every** typed
failure and **every** cancellation through OCaml exceptions:
`Runtime_core.Raised_cause` carries a typed cause across fibers, and the runtime
contract recognizes cancellation by matching exceptions. A miscompilation
affecting exception-handler parameters is therefore not a peripheral risk for
this library; it is a risk to the core failure and cancellation semantics, and
the symptom would likely be a wrong or lost typed failure rather than a clean
crash.

A global compiler flag also has a much wider blast radius than a source change:
it applies to every package in a release build, including the HTTP stack and the
AI providers, while the tests that were run against it covered the effect core,
the Eio backend, and the executable-law suite. `dune build --profile release
@install` was clean and those suites passed, but the http-testsuite and fuzz
aliases were never exercised against it.

Trading a verified 12.5% on one queue row for an unquantified risk to typed
failure propagation is the wrong trade for a library whose selling point is
typed, structured failure handling.

If the reaper is revisited, the bar is: a compiler containing the fixes listed
above, plus green `@interop`, `@cve-regress`, `@h2spec`, and the fuzz aliases
under the release profile, plus a measured win that reaches the effect core
rather than a single wrapper row.

Two pre-existing release-profile test failures were found while investigating
this, and both reproduce with `-O3` alone, so neither is attributable to any
flag discussed here:

- `test/laws/map_representation_properties.ml`
  `map_singleton_starts_fresh_ancestry` (law `smdiff-91zh`) asserts that two
  independently built, structurally identical singletons share no node. Physical
  distinctness of separately constructed immutable records is not an OCaml
  guarantee, and the optimizer may coalesce them.
- `test/par/test_eta_par_island.ml` `worker_died captures exception details`
  fails its "worker die backtrace" assertion, consistent with `-O3` inlining
  discarding the frames the test expects.
