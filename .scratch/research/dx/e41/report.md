# DX-E41 report — `Resource` to `Refreshable`

Evidence is compared with the sealed, unedited
[`journal.md`](journal.md) at commit `6a695562`.

## Result

`Eta.Resource` is deleted. Its cache/reload behavior now lives at
`Eta_cache.Refreshable`; `auto` is deleted and the only automatic constructor is
the callback-scoped `with_auto`. The implementation uses public
`Effect.with_supervised_background` and contains no `Spi` or daemon call.
`Eta_js.Refreshable` aliases `Eta_cache.Refreshable` and `eta_js` carries the
cache dependency; root `eta` does not.

The fixed single-`'err` signature was retained without deviation.

## Gates

All four exact gates passed on the final source/test implementation, on their
first gate attempt:

| gate | result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo` | PASS |

Focused pre-gate verification also passed for `test/core_eio`, `test/cache`,
`test/api_dx`, both migrated examples, and the native cache/core/example build
targets. Both examples were executed: automatic refresh produced versions
`1 -> stale 1 -> 2` with one recorded/observed failure; manual refresh produced
`1 -> 2 -> stale 2` with no automatic failure record.

## Scope-exit evidence

The `Refreshable` shared suite executes a blocked refresh before each body exit
and checks refresh finalization plus a stable exact load count:

| required exit/evidence | named executable |
| --- | --- |
| body success | `Refreshable with_auto stops loop on body success` |
| body typed failure | `Refreshable with_auto stops loop on body typed failure` |
| body defect | `Refreshable with_auto stops loop on body defect` |
| parent cancellation | `Refreshable with_auto stops loop on body cancellation` |
| in-flight checkpoint cancellation and awaited finalizer | `Refreshable with_auto cancels and finalizes in-flight refresh` |
| public empty fiber accounting | `Refreshable with_auto leaves empty fiber census` in `test/cache/test_eta_cache.ml` |

The in-flight test holds refresh cleanup behind a promise, observes that the
outer call is still unresolved, then releases cleanup and observes outer
completion. This distinguishes “cancellation requested” from “child cancelled,
awaited, and finalized.” R170 registers the matrix with exact source spans.

## Preservation evidence

| contract | evidence |
| --- | --- |
| seed once; failure suppresses body | `manual seed failure returns no handle`; `with_auto seed failure skips body` |
| stale while refresh runs or fails | `newer refresh wins` reads the old value while blocked; `with_auto failed refresh keeps cached value` checks failure |
| later successful refresh publishes | scheduled failure/defect tests and the ordered Fail/Die test finish on the later value |
| typed/defect classification and observation order | `failures preserve Fail Die observation order` observes `[Cause.Fail; Cause.Die]` |
| `on_error` defect is appended after typed failure and loop continues | `with_auto records on_error defect and continues` |
| schedule exhaustion ends only the loop | `with_auto schedule exhaustion keeps handle usable` checks the final value and exact seed-plus-refresh load count |
| manual diagnostic baseline | `manual failures start empty` |

The law registry promotes the moved/amended claims from historical package debt
to R167-R175: registered-external rows `169 -> 178`, covered rows `285 -> 294`,
with no new debt and no qcheck-count change.

## Census and footgun

Method: count public compilation modules and every `val` in their public
interfaces, including nested public signatures. Root excludes the private
`runtime_supervisor.mli` module.

| surface | before | actual after | delta | sealed prediction |
| --- | ---: | ---: | ---: | --- |
| root `eta` modules | 29 | 28 | -1 | exact hit |
| root `eta` vals | 490 | 485 | -5 | exact hit |
| `eta_cache` public compilation/exposed modules | 1 | 2 | +1 | exact hit |
| `eta_cache` vals | 8 | 13 | +5 | exact hit |
| `Eta_js` module declarations | 22 | 22 | 0 | delta hit; sealed baseline was off by one (`21`) |

Footgun actual: **-1/+0 (net -1), exact hit**. The removed footgun is the
collision between a stale-while-refresh cache named `Resource` and Eta's actual
acquire/release resource model. `with_auto` adds no detached lifetime.

Final implementation/evidence diff after the predictions commit: **33 paths,
853 additions, 229 deletions, 1,082 line events** (Git rename detection counts
the moved implementation as a rename).

## Scored sealed predictions

| prediction | verdict | evidence |
| --- | --- | --- |
| root/cache census deltas | **HIT** | all four counts exact |
| `Eta_js` alias rename is cardinality-neutral | **PARTIAL** | delta exact; sealed absolute baseline `21` should have been `22` |
| footgun delta `-1/+0` | **HIT** | old collision removed; no new public background owner |
| 22-30 paths and 300-550 line events | **MISS** | final stats exceed both bands; the all-exit matrix, exact registry, stale-reference cleanup, and evidence files dominated |
| no hold trigger | **HIT** | only examples/tests/API-DX fixtures consumed `auto` |
| six-part exit/census matrix | **HIT** | all named cases pass, including held cleanup and empty census |
| review reservations: awaited cleanup and dependency direction | **HIT** | held-finalizer test; root opam/Dune has no cache dependency; native/mainline package gates pass |

Score: **5 hits, 1 partial, 1 miss**.

## Hold-trigger audit

No runtime-owned-lifetime need was found. The complete non-document `auto`
consumer set was two examples/test surfaces plus `Eta_js`'s module alias; there
was no library/production constructor call.

Representative raw pre-change quotes:

```ocaml
(* examples/cached_resource.ml *)
let* resource =
  Resource.auto ~load:(load source) ~schedule
    ~on_error:(fun err -> observed := render_error err :: !observed)
    ()
in
let* initial = Resource.get resource in
```

The example's remaining reads, delays, and failure inspection all occurred in
the same `program` effect, so they moved verbatim inside one `with_auto` body.

```ocaml
(* test/core_common/resource_common_suites.ml *)
let resource =
  run_ok rt
    (Resource.auto ~load ~schedule:(refresh_schedule 2 (Duration.ms 5)) ())
in
```

This was test scaffolding for the old daemon lifetime, not application demand;
the migrated test holds the lexical body open explicitly.

```ocaml
(* test/api_dx/api_dx_examples.ml *)
let* resource = Eta.Resource.auto ~load ~schedule ~on_error:observe () in
Eta.Resource.get resource
```

This was a proposed API snippet, not a runtime-owned production requirement. It
now teaches callback ownership. **Hold trigger: none.**

## Red-team outcome

[`redteam/README.md`](redteam/README.md) records the old bug: wrapping
`Resource.auto` in `Effect.with_scope` looked release-fenced but left its daemon
runtime-owned. Three new-shape attempts were made: return/capture the handle,
exit through failure/defect/cancellation, and reconstruct detachment from public
cache/effect API. All fail to leak the refresh child. A handle may escape and
remain manually usable; automatic work is cancelled and awaited first. Recreating
the old lifetime requires leaving the public API for `Eta.Spi.daemon`.

Verdict: **PASS — no public refresh-loop leak.**

## Deviations and process notes

1. No contract deviation: `with_auto` keeps one `'err` throughout.
2. The stale-name census found more direct prose/topology references than the
   objective's shorthand “4 docs files”; all direct E41 references were updated,
   including repository guidance and `examples/README.md`.
3. OCaml callback inversion with the fixed optional `?random` parameter requires
   explicit `?random:None` at `let@` partial-application sites. Direct callback
   calls omit it normally. The signature was not reordered.
4. Before the exact gates, the new focused suite caught two test-authoring
   mistakes: backend cancellation may be reported as returned interruption, and
   observing two failures did not yet prove the later successful publish. Both
   assertions were fixed at their observation boundary; all exact gates then
   passed first attempt.

## Recommendation

**PROMOTE.** The package direction is correct, the misleading root path and
daemon constructor are deleted without shims, the lexical owner is implemented
entirely on public machinery, every preserved/amended interface claim has named
coverage, and native plus js_of_ocaml gates are green.
