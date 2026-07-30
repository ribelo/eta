# DX-E44 report — observability full split

## Recommendation

**PROMOTE.** Root-to-SDK dependency is absent, all four required gates are
green, the affected runtime watchlist stays below 2% regression, no raw
fiber-local key is exposed, and the mainline js_of_ocaml gate uses the same
single `eta_observability` package.

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

The first final `runtest` attempt hit the existing flaky stream test `timeout
closes from file`; its focused 16-test suite passed immediately and the second
exact full command passed. See `evidence/gates.txt`.

The mainline gate compiled and ran the shared JS suites after the split. No
`lib/jsoo` observability implementation or second SDK was introduced, so the
single-package claim is verified rather than inferred from OxCaml.

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

The affected native executable was measured with 15 alternating before/after
pairs and three samples per row (45 per side). Every changed-path wall
regression is below 2%; the maximum is **+1.936%**. Allocation is equal or
lower on every changed row. Larger improvements come from removing intermediate
optional/log/metric allocations. Full raw data and unchanged noisy controls are
in `evidence/bench-parity.md`, `bench-parity.csv`, and `bench-pairs/`.

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
  construction before allocation and the benchmark proves no allocation
  regression.
- The exact all-benchmark harness remains blocked by the pre-existing
  TypeScript `Effect.with_scope` mismatch; E44 did not modify that adjacent
  workload.
- F10 was closed when the touched `eta_stream` package-map row stopped claiming
  backend neutrality and named its Eio integration points honestly.

## Law registry

Moved law-bearing contracts now point to
`lib/observability/eta_observability.mli`. Mixed dynamic-override row R88 was
split by package boundary, defect diagnostics received direct row R90b, and
shifted root pointers were refreshed. Registered executable suites passed under
the full and shipped gates.

## Final verdict

All promote conditions are satisfied. The broad unstable SPI is the review's
weakest design point, but it preserves the stronger boundary: root owns runtime
state and protocols; the optional SDK owns application-facing observability.
