# OS4 Branch-Elision Probe

Date: 2026-05-24

Status: accepted as R-T0 follow-up evidence. Strict zero-branch dispatch is
possible only with an Eta runtime dispatch extension, not with an eta-otel-local
change.

## Question

Can Eta satisfy R-T0's strict zero observer-branch requirement while preserving
the existing runtime observer API?

The tested distinction is narrow:

- dynamic runtime flag: current style, one runtime value contains
  tracing_enabled;
- generated no-observer runtime: a statically separate path that never owns an
  observer flag;
- generated observed runtime: a statically separate path that always calls the
  observer.

## Fixture

- bench/r_t0_branch_elision/r_t0_branch_elision.ml
- .scratch/research/evidence/eta_otel_v2/r_t0_transparent_cost/os4_branch_elision/run.sh

Run:

~~~sh
.scratch/research/evidence/eta_otel_v2/r_t0_transparent_cost/os4_branch_elision/run.sh
~~~

The runner builds the fixture, executes it, disassembles the relevant symbols,
and checks for the observer-enabled branch marker.

## Evidence

~~~text
dynamic=2 static_noop=3 static_observed=4
entry_symbol=camlDune__exe__R_t0_branch_elision__entry
noop_symbol=camlDune__exe__R_t0_branch_elision__named_2_10_code
observed_symbol=camlDune__exe__R_t0_branch_elision__named_3_11_code
dynamic_observer_branch_markers=2
noop_observer_branch_markers=0
observed_observer_branch_markers=0
~~~

Dynamic runtime path excerpt:

~~~text
547b5: 48 8b 7b 08  mov 0x8(%rbx),%rdi
547b9: 48 83 ff 01  cmp $0x1,%rdi
547bd: 75 1c        jne 547db
~~~

Generated no-observer path:

~~~text
0000000000054670 <...__named_2_10_code>:
  54670: 48 83 ec 08  sub $0x8,%rsp
  54674: 4d 3b 3e     cmp (%r14),%r15
  54677: 76 0e        jbe 54687
  54679: b8 01 00...  mov $0x1,%eax
  5467e: 48 8b 3b     mov (%rbx),%rdi
  54685: ff e7        jmp *%rdi
~~~

The no-observer path still has ordinary OCaml stack-check branches. It does not
have the observer-enabled flag branch.

## Verdict

The current dynamic flag shape cannot support a literal zero observer-branch
claim for no-observer hot paths when the runtime value is not statically known.
That matches the original R-T0 counterevidence from source inspection.

A generated/static no-observer path can remove the observer branch in the
minimal fixture. To preserve Eta's existing user-facing Runtime.create
?tracer ?logger ?meter API, the split must happen inside Eta.Runtime, likely as
a runtime-level dispatch to separate no-observer and observed interpreters.

Do not implement this inside eta-otel. eta-otel can preserve the current public
claim:

- no eta-otel linkage when eta-otel is not linked;
- zero measured allocations on covered noop observer paths;
- no strict zero-branch guarantee yet.

## Required Eta Extension

Add an Eta-owned runtime dispatch extension before claiming strict R-T0:

- Runtime.run selects a no-observer interpreter when tracer, logger, meter,
  and auto-instrumentation are disabled.
- The no-observer interpreter has no observer-enabled checks in named,
  annotate, log, metric, blocking-event, and auto-instrument leaves.
- The observed interpreter preserves current tracer/logger/meter semantics.
- Regression evidence must include assembly or equivalent generated-code proof
  plus existing Eta observability tests.

## Limits

This probe is not a production implementation. It proves feasibility of the
shape and falsifies the stronger claim that the current dynamic flag runtime is
already strict-zero-branch.
