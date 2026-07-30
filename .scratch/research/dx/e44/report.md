# DX-E44 report — observability full split

## Recommendation

**PROMOTE.** Root-to-SDK dependency is absent, all required gates are green, no
raw fiber-local key is exposed, and the mainline js_of_ocaml gate uses the same
single `eta_observability` package. The expanded batch watchlist has
deterministic allocation parity and pooled wall medians near parity, with the
per-pair spread and lack of a statistical upper bound stated explicitly below.

## Result

- Added opam package/public library/top module `eta_observability` /
  `eta_observability` / `Eta_observability`.
- Moved `Logger`, `Meter`, `Tracer`, `Log_level`, `Trace_context`, and all 40
  application-facing observability vals.
- Root `eta` retains `Capabilities`, `Runtime_contract`, `Spi.Expert`, private
  interpreter state, private noop capabilities, and defect/span diagnostics.
- Deleted the old root modules and `Effect` paths. There are no forwarding
  aliases or compatibility shims.
- PPX sync/result expansion now combines root `Eta.Effect.sync`/`sync_result`
  with `Eta_observability.named`/`fn`; generated users need the SDK dependency.

## Fiber-local seam decision

Every key read or written by root remains private in root, including active
span, sampling/ambient context, defect context, capability overrides, daemon log
scope/filter/interceptors, and SPI metric interceptors. The SDK receives narrow
behavioral operations through abstract `Spi.Expert.context`; **zero raw keys**
are exposed (within the allowed maximum of one).

Private `Runtime_capabilities` objects replace root's former use of public
`Logger.noop`, `Meter.noop`, and `Tracer.noop`. Private
`Runtime_trace_context` retains only validation/sampling needed by span
parenting. `Effect_instrument` keeps root background naming without a public SDK
edge. The SDK still builds ordinary `Custom` leaves through `Spi.Expert.make`;
the interpreter ADT and dispatch branch are unchanged.

Proof: `evidence/dependency-direction.txt` records `eta (requires ())` and
`eta_observability (requires (eta-uid))` from Dune.

## Gates

| Required command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force` | PASS |

The first final `runtest` attempt hit the existing flaky stream test `timeout
closes from file`; its focused 16-test suite passed immediately and the second
exact full command passed. See `evidence/gates.txt`.

The follow-up reran the native trio after the final batch and contract changes.
The mainline build gate compiled the shared JS closure; the additional focused
mainline `runtest` executed the new `runtime local binding contract` test and the
complete eta_jsoo/eta_js_jsoo suites. No `lib/jsoo` observability implementation
or second SDK was introduced.

## Census and migration completeness

| Measure | Expected/sealed | Actual | Score |
| --- | ---: | ---: | --- |
| root `Effect.mli` vals | 79 | 79 | exact |
| SDK vals | 40 | 40 | exact |
| opam packages | 49 | 49 | exact |
| dependency direction | SDK -> root only | SDK -> root only | exact |
| raw Spi-exposed shared keys | 0 | 0 | exact |

The orchestrator's rough root estimate was `85±3`; the executor prediction of
79 counted the advanced context surface plus `with_error_pp`,
`suppress_observability`, and `here_attr`, and matched the full split.

The pre-implementation-to-migration range changes 245 files. A diff census
found 1,050 removed old-path lines outside root/new-SDK/forbidden research,
broader than the approximate 510 call-line estimate because it includes tests,
typecheck fixtures, examples, benches, and current docs. The committed
`evidence/stale-references.sh` reports zero stale OCaml code references, and all
installable/test gates compile the migrated graph.

## Benchmark parity

The exact `nix develop -c bash bench/run.sh --quick` command fails both before
and after E44 in the unchanged TypeScript comparison workload because
`Effect.with_scope` is unavailable. Matching raw failures are committed.

The first paired run measured the single-point paths but omitted
`metric_updates`, `metric_updates_lazy`, and batch interception. Its broad
"every changed path" conclusion is withdrawn; the historical files remain for
provenance.

The follow-up added all three batch rows at 100,000 points and reran 15
alternating pairs with three samples per row. Relative to pre-split `fd27e518`,
pooled wall-median deltas are **+0.873%** for eager batches, **-16.110%** for
lazy batches, and **-0.239%** under a `Keep` interceptor. The respective
per-pair min/median/max spreads are **-16.041/+1.186/+10.178%**,
**-22.036/-15.735/-3.820%**, and **-8.042/+0.367/+10.083%**.

These descriptive samples do not establish a confidence interval or a
one-sided upper bound. Unchanged controls also moved positively in the same run
(noop tracer pooled medians +2.897% and +4.492%), so pair extrema are not
represented as split-only cost.

The structural allocation finding is resolved: the final producer receives one
uniform timestamp and streams each point once, with no placeholder record,
timestamp copy, or point-list allocation. Eager and intercepted batches differ
from pre-split by four words total across 100,000 points; lazy batches allocate
199,995 fewer words. The broken split allocated 1,100,003 extra words in the
eager/intercept rows. Method, raw pairs, smoke comparison, patch, analyzer, and
full CSV are in `evidence/bench-followup-pairs/`.

## Red-team outcomes

1. **Root-only combinator call:** expected compile failure, `Unbound module
   "Eta_observability"`.
2. **Real graph cycle:** temporarily adding root -> SDK makes Dune reject
   `eta -> eta_observability -> eta`; the script restores the file under trap.
3. **Root-only hand-written tracer:** without an SDK dependency, a defective
   internally named effect emits an `exception` event with `exception.type` and
   `eta.cause.path` to the supplied `Capabilities.tracer`.

Sources and raw outputs are in `redteam/`.

## Sealed predictions scored

- Expected-result predictions: **5/5** (package, flat surface, 79-val root,
  one-way graph, Custom-leaf mechanism/parity).
- Seam predictions: **3/4 exact, 1 partial**. Key ownership, zero exposed keys,
  and private noops matched. The public `Trace_context` implementation retained
  its own validation while root kept a 26-line private minimum rather than
  delegating the public helper through root substrate as predicted.
- Likely break classes: **2/2**. Root noop/context/background/pool coupling and
  PPX/dependency/mainline migration were exactly the two classes encountered.

Overall: **10 exact, 1 partial, 0 contradicted**.

## Deviations and footguns

- Required read-first `.scratch/research/dx-ledger.md` was absent. The forbidden
  similarly named `docs/research/dx-ledger.md` was not substituted.
- One repository-wide exclusion search accidentally returned matching lines
  from forbidden `docs/research/`. No file there was opened separately, edited,
  or staged; the journal records this procedural violation raw.
- OxCaml accepted a new private helper named `effect`, while upstream OCaml 5.4
  reserves it. The mainline gate exposed this immediately; it was renamed
  `effect_of_public`.
- The first implementation built metric points before admission. Independent
  seam review caught the regression; the final implementation gates point/batch
  construction before allocation.
- A later independent review found that admitted batches still built a
  placeholder point and copied it to install the timestamp, while the original
  watchlist omitted batch paths. The final timestamp-aware streaming producer
  constructs each point exactly once; the expanded allocation evidence is at
  pre-split parity. The earlier broad below-2% claim was replaced with pooled
  deltas plus the full per-pair spread and no one-sided bound.
- The exact all-benchmark harness remains blocked by the pre-existing
  TypeScript `Effect.with_scope` mismatch; E44 did not modify that adjacent
  workload.
- F10 was closed when the touched `eta_stream` package-map row stopped claiming
  backend neutrality and named its Eio integration points honestly.

## Law registry

Moved law-bearing contracts now point to
`lib/observability/eta_observability.mli`. Mixed dynamic-override row R88 was
split by package boundary, defect diagnostics received direct row R90b, and
shifted root pointers were refreshed. Follow-up row R110b makes
`local_with_binding` restoration, LIFO nesting, fork snapshots, and no
join-merge backend conformance requirements, with native and jsoo named tests
plus both reference implementations. R90 now registers the three corrected SDK
qualifications. The registry contains 186 external clusters.

## Final verdict

All promote conditions are satisfied. The broad unstable SPI is the review's
weakest design point, but it preserves the stronger boundary: root owns runtime
state and protocols; the optional SDK owns application-facing observability.

The first independent final review blocked on R90b's incorrect executable
pointer and the external-row headline count. Commit `b66c56ec` corrected those
items and the stale `with_external_parent` error-path name. The follow-up review
then identified F1–F4. Its first re-review found stale shifted law pointers and
insufficient fork-isolation discrimination; commit `c2249a62` refreshed every
pointer and synchronized both backend tests. The same reviewer independently
recounted 186 external rows, reran native and jsoo suites, and returned
**READY** with no remaining blockers.
