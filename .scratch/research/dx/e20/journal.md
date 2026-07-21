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
