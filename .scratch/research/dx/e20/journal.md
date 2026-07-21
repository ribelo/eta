# DX-E20 decision journal

## V-DX-E20-001 — sealed predictions

Status: SEALED before E20 code or public-contract changes.

### Decision and constraints

Decide whether Eta should ship fiber-local `Effect.intercept_log` and
`Effect.intercept_metric` transforms over the existing observability pipeline.
The log half may survive independently; the metric half must earn its place with
an honest subtree label-enrichment example. Existing `annotate_logs` and
`with_minimum_log_level` remain unchanged and are the behavioral baseline.

Polysemy is vocabulary provenance, not an architecture dependency. Its
`intercept` is documented as responding to an effect while leaving it unhandled,
so logic can be inserted around the existing interpreter. Eta imports that
interposition idea only, specialized to log records and metric points:
<https://hackage.haskell.org/package/polysemy-1.9.1.3/docs/Polysemy.html#v:intercept>.

### Proof obligations

| ID | Proof question | Minimum fair evidence | Risk | Predicted result |
| --- | --- | --- | --- | --- |
| E20-P1 | Is pipeline order exactly min-level filter → scoped/per-call attrs → intercept → current sink? | Call trace plus sink assertions, including logger override both inside and outside | High | Proven in both override nestings |
| E20-P2 | Do nested transforms run outermost-to-innermost and short-circuit on `None`? | Two-transform trace and dropped-sink test | High | Outer runs first; an outer `None` prevents inner and sink; an inner `None` runs after outer and prevents sink |
| E20-P3 | Are old shorthands unchanged? | Existing suites unchanged plus focused parity observations | Medium | Byte-identical records and filtering |
| E20-P4 | Does the general mechanism earn both examples? | Executable password redaction and metric tenant enrichment | Medium | Both are materially clearer than hand-wrapped sinks; metric survives |
| E20-P5 | Is identity-transform cost acceptable? | Watchlist no-intercept denominator versus `Some`-identity, time and allocation | Medium | Runtime delta within ±5% local run noise and zero additional measured minor words per emitted record |
| E20-P6 | Does the log behavior remain portable? | Native tests and jsoo parity test | Medium | Same transform/drop behavior |
| E20-P7 | Does a raising transform follow ordinary defect capture? | Executable raising transform | Medium | `Exit.Error (Cause.Die _)`; no sink call |

### Hypothesis ledger

| Candidate | Why plausible | Evidence needed to win | Falsifier | Initial status |
| --- | --- | --- | --- | --- |
| A — ship both specialized interceptors | One scoped transform protocol covers redaction, sampling, assertion, and metric labels without replacing sinks | All P1–P7, including compelling metric fixture | Ambiguous order, allocation regression, or contrived metric story | Favored, active |
| B — ship log only | Redaction/drop is clearly valuable while metric labels may already be sufficiently explicit per call | Log proofs pass and metric comparison fails honest review | Metric fixture removes repeated sink/producer plumbing with clear subtree scope | Active kill alternative |
| C — sink wrappers only | Ordinary object delegation can transform records without new public vals | Review old fixtures remain equally local and compose correctly with scoped sinks | Repeated wrapper plumbing or wrong lexical scope/order | Baseline, active |

### Quantitative predictions

1. Public census: observability cluster **+2 vals / +1 concept**; no public type
   or dependency growth.
2. Existing shorthand suites pass without edits to shorthand implementation.
3. Identity interception adds exactly one transform call per record. The emitted
   record itself is reused; the benchmark reports zero incremental allocation
   and elapsed-time delta no worse than 5% against its denominator. If local
   variance crosses that boundary, report it honestly rather than relabeling it
   noise.
4. The metric case survives review because subtree-wide `tenant=acme`
   enrichment removes producer-by-producer labels without replacing the meter.
5. Prediction score uses one point for each of P1–P7, with partial credit only
   where evidence is explicitly partial.

### Three trap candidates, expected to be disarmed by contracts

1. A caller expects interception to observe a record already dropped by the
   minimum-level filter. It cannot: filtering is first.
2. A caller reads nesting like sink wrappers and expects the inner transform to
   run first. It does not: transforms run outermost-to-innermost.
3. A caller expects `with_logger` placement to choose whether transformation
   happens. It does not: interception transforms the record before whichever
   sink is currently bound.

Predicted disclosed footguns: **+0** after these three are stated and tested.

### Disconfirming evidence sought

- Force the favored design through an inner drop and a raising transform rather
  than testing only identity/enrichment.
- Compare the metric API with the strongest ordinary baseline: a delegating
  meter wrapper, not a deliberately repetitive per-call toy.
- Preserve the denominator and allocation fields for the benchmark; do not use
  a standalone flattering timing.

Would change the decision: a repeatable allocation increase on identity,
composition that cannot match the contracted order without broader machinery,
jsoo divergence, shorthand regression, or a metric review fixture where the old
wrapper is honestly clearer.

## V-DX-E20-002 — implementation and behavioral evidence

Status: ACCEPTED for semantics; performance verdict deferred to V-DX-E20-003.

Decision: implement the smallest fiber-local transform lists over the existing
runtime locals. Scope entry appends a transform to the inherited list. Emission
walks that list in order and returns immediately on `None`. Log emission reaches
the list only after level admission and record construction; metric emission
reaches it after timestamped point construction.

Evidence:

- `test/core_common/observability_common_suites.ml`: outer/inner call trace,
  redaction after merged attributes, drop short-circuit, filter-before-transform,
  sibling isolation, logger override in both nesting orders, raising-transform
  defect capture, metric tenant enrichment, and metric drop short-circuit.
- Existing `annotate_logs` and `with_minimum_log_level` implementations and tests
  were not rewritten. The unchanged suites passed in the full gate.
- `test/js_jsoo/test_eta_jsoo.ml`: outer-first transformation and inner drop on
  the jsoo runtime.
- `.scratch/research/dx/e20/review/`: strong object-wrapper baselines versus the
  new lexical mechanism.
- `.scratch/research/dx/e20/redteam/`: both required adversarial cases.

Counterevidence considered: a sink wrapper is sufficient when one fixed logger
owns the policy. It loses to interception when a nested `with_logger` selects a
different sink, because the wrapper is the replaced sink rather than an
independent pipeline stage. A meter wrapper is stronger than producer-by-
producer labels, but Eta has no scoped meter override; it changes runtime
construction rather than one tenant subtree.

## V-DX-E20-003 — fast-path gate contradicts the contract

Status: REJECT current promotion.

Command (OxCaml, pinned to CPU 0, 10 samples):

```sh
taskset -c 0 nix develop -c dune exec \
  bench/runtime_watchlist/runtime_watchlist.exe -- \
  --samples 10 --filter overhead.eta.log
```

The benchmark uses an enabled logger that consumes each body, 100,000 prebuilt
log effects, and the same runtime for both rows.

| Row | wall mean | wall stddev | minor words | major words |
| --- | ---: | ---: | ---: | ---: |
| no intercept | 16,629,791 ns | 127,940 ns | 5,242,876 | 67 |
| `Some`-identity intercept | 11,186,719 ns | 66,532 ns | 6,291,447 | 153 |

The wall result is 32.7% lower, not a credible interceptor speedup; installing a
fiber-local context changes the backend lookup/GC profile, so this pair cannot
isolate one function-call latency. It does establish that there is no observed
wall-time regression in this run. Allocation is diagnostic and repeatable:
identity adds 1,048,571 minor words per 100,000 records, or about 10.49 words per
record. The callback's ordinary `Some record` result and fiber-local lookup are
not allocation-free. This falsifies P5 and the public target contract. Do not
merge the branch contract as a true claim.

Counterevidence considered: the implementation itself reuses the input record
and preserves the final callback option rather than wrapping it again. That
does not make an opaque standard-OCaml callback returning a boxed `option`
allocation-free. OxCaml-only local return modes also cannot repair a public API
that must compile on upstream OCaml 5.4.

Would change the decision: a revised portable callback representation with an
immediate identity/keep result (for example an explicit `Keep` case), followed
by the same denominator benchmark showing zero incremental allocation.

## V-DX-E20-004 — final prediction score and recommendation

Status: PARTIAL; experiment complete, promotion rejected.

| Obligation | Result | Score |
| --- | --- | ---: |
| P1 pipeline and sink order | Proven | 1 |
| P2 outer-first/drop short-circuit | Proven | 1 |
| P3 shorthand parity | Proven by unchanged implementations/suites | 1 |
| P4 redaction and metric use cases | Proven | 1 |
| P5 identity fast path | Contradicted by allocation | 0 |
| P6 jsoo parity | Proven | 1 |
| P7 raising transform capture | Proven | 1 |
| **Total** |  | **6 / 7** |

Hypothesis outcome:

- A — ship both specialized interceptors: **REJECTED for the fixed one-pager
  contract**, solely because the measured identity path allocates.
- B — ship log only: **REJECTED under the same allocation contract**; dropping
  metric does not fix the log callback representation.
- C — sink wrappers only: **BASELINE RETAINED** until the callback contract is
  revised. It remains less compositional but makes no false fast-path promise.

Metric fate, considered separately: the lexical tenant example is compelling
and passes executable review evidence, so the one-pager's metric-use-case kill
condition does **not** fire. Retain `intercept_metric` in a future revised design;
do not promote either half from this branch while the shared allocation claim is
false.

Census: observability cluster +2 vals / +1 concept, public types +0,
dependencies +0. The three sealed traps are all explicitly documented and
tested; undisclosed footguns +0. Behavioral predictions were accurate, but the
quantitative allocation prediction was wrong.

Final exact gates, all PASS:

- `nix develop -c dune build @install`
- `nix develop -c dune runtest --force`
- `nix develop -c eta-oxcaml-test-shipped`
- `nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo`

Additional parity gate PASS:
`nix develop .#mainline -c dune runtest test/js_jsoo --force`.

## V-DX-E20b-001 — representation-fix predictions (sealed)

Status: SEALED before E20b code or public-contract changes. This entry amends
the implementation hypothesis; it does not alter the sealed E20 predictions.

Decision: test the public result type
`type 'a intercept = Keep | Drop | Replace of 'a`. `Keep` and `Drop` are
immediate constructors; `Replace value` is the only boxed successful result.
All E20 pipeline, scope, sink, drop, exception, and metric-use-case semantics
remain fixed.

| ID | Prediction | Falsifier |
| --- | --- | --- |
| E20b-P1 | The carried native and jsoo behavioral suite passes after mechanical `Some`→`Keep`/`Replace` and `None`→`Drop` updates | Any semantic trace, sink, or defect-path difference |
| E20b-P2 | A `Keep` callback itself allocates zero words and the watchlist identity row adds zero minor words over no intercept | Any repeatable positive minor-word delta |
| E20b-P3 | `Replace record` adds only its variant block, at most 3 words per emitted record | Delta above 300,000 minor words for 100,000 records after accounting against the same denominator |
| E20b-P4 | Identity wall time does not regress beyond local measurement noise | Identity mean materially above baseline on the pinned watchlist run |
| E20b-P5 | The three constructors read clearly in redaction, metric enrichment, and a dedicated readability snippet | Review packet requires explanatory machinery beyond the constructor contract |

Strongest risk: E20 measured about 10.49 incremental minor words per record,
while an ordinary boxed `Some record` explains only part of that total. Active
fiber-local lookup may allocate option wrappers before the walker invokes the
callback. E20b is constrained to the transform representation; if that residual
cost remains, record it raw rather than changing the backend or benchmark.

Hypothesis ledger:

- A — `Keep | Drop | Replace`: **favored, active**. It makes identity/drop
  representation explicit and portable across OxCaml and upstream OCaml 5.4.
- B — retain standard `option`: **rejected by E20 evidence** and the follow-up
  contract.
- C — optimize runtime-local lookup too: **out of scope** unless a later sealed
  experiment authorizes a backend change; it is not a representation fix.

Predicted outcome: behavior and readability pass. `Keep` removes the callback's
boxed identity result, but confidence in the sealed zero-increment end-to-end
bar is low because of the measured lookup residual. `Replace` is expected to
allocate one 2-word block for the unary variant itself; any larger end-to-end
delta will distinguish walker/local overhead from representation cost.

Scoring: one point each for P1–P5. Promotion requires P1 plus the orchestrator's
allocation and wall gates; the metric half remains separately justified by the
already compelling tenant-subtree fixture.
