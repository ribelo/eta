# ADR 0001: Runtime Observability Dispatch

Status: Proposed

Date: 2026-05-24

## Context

Track O R-T0 asks for eta-otel to be effectively free when an application does
not wire eta-otel into Eta.Runtime: no eta-otel linkage, no measured allocation,
and no observer branch on no-observer hot paths.

Package separation already proves the linkage claim. Current runtime flags
already prove zero measured allocation on covered noop observer paths. They do
not prove literal zero branch cost: Runtime.interpret still checks
tracing_enabled, logging_enabled, metrics_enabled, and auto_instrument in the
interpreter.

The OS4 branch-elision probe shows a generated/static no-observer path can
remove the observer-enabled branch, while the current dynamic flag shape emits
the branch when the runtime value is not statically known.

## Decision

Do not solve strict zero-branch dispatch inside eta-otel.

The Eta-owned extension, if accepted, is a runtime dispatch split:

- Runtime.run selects a no-observer interpreter when tracer, logger, meter, and
  auto-instrumentation are disabled.
- The no-observer interpreter has no observer-enabled checks in named,
  annotate, log, metric, blocking-event, or auto-instrument leaves.
- The observed interpreter preserves current tracer/logger/meter behavior.
- The public Runtime.create observer API remains source-compatible.

## Consequences

eta-otel must not claim strict zero-branch transparent cost until Eta.Runtime
has this split or equivalent generated-code proof.

The current valid claim remains narrower:

- applications that do not link eta-otel do not contain eta-otel, eta-http, or
  yojson symbols;
- covered noop tracer/logger/meter hot paths allocate zero measured words;
- current Eta.Runtime still has dynamic observer branches.

## Verification Required Before Acceptance

- Assembly or equivalent generated-code proof that the no-observer interpreter
  removes observer-enabled branches.
- Existing Eta observability tests pass unchanged for the observed path.
- Pay-as-you-go allocation benchmark remains zero on noop observer cases.
- eta-oxcaml-test-shipped passes.

## Reference Evidence

- .scratch/research/evidence/eta_otel_v2/r_t0_transparent_cost/verdict.md
- .scratch/research/evidence/eta_otel_v2/r_t0_transparent_cost/os4_branch_elision/verdict.md
- bench/r_t0_branch_elision/r_t0_branch_elision.ml
