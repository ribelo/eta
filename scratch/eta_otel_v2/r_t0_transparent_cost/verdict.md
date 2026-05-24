# R-T0 Transparent Cost Verdict

Date: 2026-05-23

Status: OS4 follow-up recorded. OS0 through OS3 may proceed on the current
baseline. Strict zero-branch transparent cost requires an Eta runtime dispatch
extension and must not be claimed by eta-otel yet.

## Question

If an application does not wire eta-otel into Eta.Runtime, can eta-otel be
effectively free at runtime?

The objective's strict proof obligations are:

- zero allocation on no-observer hot paths;
- zero branch cost on no-observer hot paths;
- zero binary bloat from unreachable eta-otel code.

## Current Runtime Facts

Current Eta.Runtime already distinguishes noop observers from real observers
with tracing_enabled, logging_enabled, and metrics_enabled flags. Those flags
skip observer object calls and avoid payload construction on the noop paths.

That mechanism is useful, but it is not a literal zero-branch mechanism. Source
inspection still shows runtime conditionals in the interpreter for annotate,
log, and metric effects. The current evidence supports a narrower claim:
zero allocations on measured noop observer hot paths, plus no eta-otel binary
linkage when eta-otel is not linked.

## Hypothesis Ledger

| Candidate | Why it is plausible | Evidence needed to win | Evidence that would falsify it | Current evidence | Status |
| --- | --- | --- | --- | --- | --- |
| A. Runtime flags plus package separation | It matches the existing Eta.Runtime shape, keeps eta-otel outside programs that do not link it, and already skips noop observer calls. | No allocation in noop observer benchmarks; no eta-otel symbols in an eta-only executable; source inspection confirms payload creation is guarded. | Noop observer paths allocate; eta-only executable contains eta-otel/eta-http/yojson symbols; strict zero-branch is required now. | Benchmarks show zero minor and major words for noop tracer/logger/meter cases. nm finds no eta-otel, eta-http, or yojson symbols in the eta-only fixture. Runtime source still contains branches. | Accepted baseline for OS0/OS1; incomplete for strict OS4. |
| B. Compile-time or generated dispatch elision | It is the strongest candidate for literal zero-branch cost while keeping runtime observers available in instrumented builds. | A fixture proving disabled instrumentation compiles to no observer branch while enabled instrumentation preserves the Tracer API and tests. | It breaks the Tracer API, forces unacceptable call-site burden, or still emits runtime branches in disabled mode. | OS4 branch-elision probe shows a generated no-observer path removes the observer branch, while the dynamic flag path still emits it. Preserving the public Runtime.create API requires an Eta.Runtime dispatch split. | Accepted as Eta extension, not eta-otel-local work. |
| C. Always link eta-otel and rely on a noop exporter | It is operationally simple and avoids dispatch design work. | It would need to avoid binary/dependency bloat despite always linking eta-otel. | Minimal programs contain eta-otel transport/encoder symbols, or the package boundary no longer protects non-otel applications. | The linkage fixture shows package separation avoids eta-otel symbols entirely when eta-otel is not linked; an eta-otel-linked fixture contains eta-otel symbols. | Rejected as dominated by A on the bloat obligation. |

## Evidence

Fixtures:

- bench/r_t0_linkage/no_otel_eta_only.ml
- bench/r_t0_linkage/with_otel_linked.ml
- bench/r_t0_branch_elision/r_t0_branch_elision.ml
- bench/results/eta-r-t0-paygo-current.json
- scratch/eta_otel_v2/r_t0_transparent_cost/os4_branch_elision/run.sh
- scratch/eta_otel_v2/r_t0_transparent_cost/os4_branch_elision/verdict.md

Build and smoke:

~~~text
nix develop -c dune build bench/r_t0_linkage/no_otel_eta_only.exe bench/r_t0_linkage/with_otel_linked.exe
exit 0

EIO_BACKEND=posix nix develop -c dune exec bench/r_t0_linkage/no_otel_eta_only.exe
no_otel_eta_only=ok

nix develop -c dune exec bench/r_t0_linkage/with_otel_linked.exe
with_otel_linked=102
~~~

Linkage:

~~~text
nm _build/default/bench/r_t0_linkage/no_otel_eta_only.exe | rg -i 'camlEta_otel|camlYojson|camlEta_http'
exit 1
output: empty

nm _build/default/bench/r_t0_linkage/with_otel_linked.exe | rg -i 'camlEta_otel|camlYojson|camlEta_http'
output includes:
000000000196fc08 D camlEta_otel
~~~

The absolute executable sizes were:

~~~text
_build/default/bench/r_t0_linkage/no_otel_eta_only.exe 43860816
_build/default/bench/r_t0_linkage/with_otel_linked.exe 43417800
~~~

Those sizes are not direct bloat evidence because the programs are not
identical. Symbol absence is the relevant linkage proof.

Pay-as-you-go observer benchmark:

~~~text
nix develop -c bash bench/run.sh --quick --filter 'noop_|in_memory_' --out bench/results/eta-r-t0-paygo-current.json
exit 0

effect.observability.noop_tracer.no_auto minor_words 0.0
effect.observability.noop_tracer.no_auto major_words 0.0
effect.observability.noop_tracer.auto minor_words 0.0
effect.observability.noop_tracer.auto major_words 0.0
effect.observability.noop_logger.log minor_words 0.0
effect.observability.noop_logger.log major_words 0.0
effect.observability.noop_meter.metric minor_words 0.0
effect.observability.noop_meter.metric major_words 0.0
~~~

bench/runtime_observability is useful for allocation evidence, but it is not a
clean binary-bloat fixture because the benchmark target itself links observation
support. The clean bloat probe lives under bench/r_t0_linkage/. Runnable
fixtures were placed under bench/ because the root Dune file treats scratch/ as
a data-only directory.

## Verdict

Proceed with the eta-otel rebuild using the existing runtime-flag and package
separation baseline. The public claim for v2 must be precise:

- no eta-otel, eta-http, or yojson symbols in programs that do not link
  eta-otel;
- zero measured allocations on current noop tracer/logger/meter hot paths;
- not a literal zero-branch guarantee.

OS4 should not claim full R-T0 closure until Eta.Runtime implements candidate B
or an equivalent runtime-level dispatch split. Candidate B is no longer merely
untested: the minimal branch-elision fixture proves the shape can remove the
observer branch, but doing so while preserving Runtime.create belongs in Eta,
not eta-otel. Candidate C is closed because it is strictly worse than package
separation for binary bloat.

## OS4 Branch-Elision Follow-Up

Command:

~~~text
scratch/eta_otel_v2/r_t0_transparent_cost/os4_branch_elision/run.sh
exit 0
dynamic_observer_branch_markers=2
noop_observer_branch_markers=0
observed_observer_branch_markers=0
~~~

The dynamic runtime path contains:

~~~text
cmp $0x1,%rdi
jne ...
~~~

The generated no-observer path has no observer-enabled branch marker. It still
has normal OCaml runtime stack checks, which are outside the R-T0 observer-cost
claim.

## Counterevidence and Open Work

- Eta.Runtime still branches on observer-enabled flags. The OS4 probe now
  confirms that this is not a mere source-level concern; the dynamic path emits
  the observer branch when the runtime value is not statically known.
- The benchmark proves zero allocation for the covered noop observer cases, not
  every possible future eta-otel call path.
- The missing scratch/eta_otel_rebuild/transparent_cost_research_plan.md
  referenced by the objective was not present in this checkout, so this verdict
  records a new hypothesis ledger rather than amending that stale plan.
- Next production step for candidate B: implement an Eta.Runtime no-observer
  interpreter split or equivalent generated dispatch, then prove the same
  branch-elision property against Eta.Runtime itself.
