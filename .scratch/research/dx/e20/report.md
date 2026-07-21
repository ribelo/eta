# DX-E20 report — log and metric interception

## Recommendation

**DO NOT PROMOTE THE CURRENT CONTRACT.** The behavioral design is coherent and
all repository gates pass, but the pre-registered fast-path allocation claim is
false for the required standard `option` callback. The branch is complete
review evidence, not a merge-ready feature.

The log and metric recommendations are separate:

- **Log half:** behavior passes; promotion is blocked by measured identity-path
  allocation.
- **Metric half:** the tenant-label fixture is compelling, so the metric-use-case
  kill condition does not fire. Keep it in a revised design, but it shares the
  callback representation problem and should not merge from this branch.

## Delivered experiment surface

- `Effect.intercept_log` and `Effect.intercept_metric`: +2 vals / +1
  observability concept.
- Two private fiber-local transform stacks and shared emission walkers.
- Existing `annotate_logs` and `with_minimum_log_level` code unchanged.
- Native common-suite tests, explicit jsoo parity, watchlist denominator pair,
  red-team artifacts, and old/new review packet.
- Public types +0; dependencies +0; compatibility paths +0.

## Required gates

All exact commands passed from the assigned worktree:

| Gate | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo` | PASS |

Additional executable JS evidence:

- `nix develop .#mainline -c dune runtest test/js_jsoo --force` — PASS,
  including `intercept_log parity`.

## Composition, drop, and parity results

The fixed log pipeline is proven as:

1. scoped minimum-level admission;
2. scoped attributes, then per-call attributes;
3. outermost-to-innermost intercept transforms;
4. the currently bound sink.

An outer transform sees the fully attributed record first. If it returns
`Some`, the inner transform sees that transformed record. `None` prevents every
later transform and the sink. A below-threshold record calls no interceptor.

`with_logger` was tested both inside and outside `intercept_log`; both selected
sinks received the scrubbed record and the base sink received nothing. The
transform therefore applies to whichever sink is active rather than replacing
that sink.

Shorthand parity is exact: their implementations were not changed, their
existing record-order/filter suites passed unchanged, and the new order test
confirms interception starts only after those stages.

Metric points use the same nesting/drop rules after point construction and
before the meter. Executable evidence enriches a subtree with `tenant=acme` and
proves a dropped point skips later transforms and the meter.

## Redaction and metric review packet

Artifacts: `.scratch/research/dx/e20/review/`.

- `redact-old.ml` is the strongest ordinary baseline: a delegating logger
  wrapper. A nested `with_logger` replaces the wrapper and its policy.
- `redact-new.ml` scopes one inline scrub independently of sink selection.
- `metric-old.ml` wraps the meter at runtime construction because Eta has no
  scoped meter override; its tenant policy is runtime-wide.
- `metric-new.ml` adds the tenant only to one lexical subtree while preserving
  the installed meter.
- `MANIFEST.md` and `QUESTIONS.md` provide the inventory and required
  teach-back prompts/key.

The metric case is honest and compelling: it changes policy scope from runtime
construction to a lexical tenant subtree. **Do not kill the metric half for
lack of a use case.**

## Fast-path benchmark

Watchlist rows:

- `overhead.eta.log.100k.no_intercept`
- `overhead.eta.log.100k.identity_intercept`

Command:

```sh
taskset -c 0 nix develop -c dune exec \
  bench/runtime_watchlist/runtime_watchlist.exe -- \
  --samples 10 --filter overhead.eta.log
```

| Row | wall mean ± stddev | minor words | major words |
| --- | ---: | ---: | ---: |
| no intercept | 16,629,791 ± 127,940 ns | 5,242,876 | 67 |
| identity intercept | 11,186,719 ± 66,532 ns | 6,291,447 | 153 |

The wall delta is -32.7%, which is not interpreted as a speedup: the scope's
fiber-local context changes backend lookup and GC behavior, so the pair does not
isolate call latency. It does show no wall-time regression in this sample.

The allocation result is decisive. Identity adds 1,048,571 minor words per
100,000 records (~10.49 words/record), repeatably. The ordinary boxed
`Some record` callback result plus fiber-local lookup is not allocation-free.
Although the implementation reuses the record and does not add another final
option wrapper, it cannot make an opaque upstream-OCaml callback's boxed option
disappear. The sealed ±5%/zero-increment prediction and the one-pager promotion
gate therefore fail.

## Red-team outcomes

Artifacts: `.scratch/research/dx/e20/redteam/`.

1. **Filter trap:** a `Debug` log under a `Warn` scope never invokes the
   interceptor and never reaches the sink. Contract and executable test agree.
2. **Raising transform:** the runtime returns `Exit.Error (Cause.Die _)`, keeps
   exception identity, and does not call the sink. The contract states ordinary
   defect capture.

No exception swallowing, fallback, or silent default was introduced.

## Census, footguns, and prediction score

- Census: observability cluster +2 vals / +1 concept; public types +0;
  dependencies +0.
- Traps recorded and disarmed by docs/tests: filter-before-intercept,
  inner-first nesting expectation, and sink-placement bypass expectation.
- Undisclosed footguns: +0.
- Prediction score: **6 / 7**. Pipeline, drop, shorthand parity, both use cases,
  jsoo parity, and defect capture passed. Allocation failed.

## Evidence verdicts

- **A — ship both interceptors:** REJECTED under the fixed allocation contract.
- **B — ship log only:** REJECTED under the same log allocation evidence.
- **C — retain ordinary sink wrappers:** BASELINE RETAINED pending a portable
  callback redesign.

A credible next candidate would represent unchanged identity with an immediate
result such as `Keep`, while reserving an allocating case for replacement. That
is outside E20's fixed signature and must be a separately sealed experiment.

Final verdict: **BEHAVIOR PROVEN; CURRENT CONTRACT NOT PROMOTABLE**.
