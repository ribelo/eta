# DX-E11 decision journal — `Eta_test.Run`

## V-DX-E11-001 — sealed predictions

Date: 2026-03-13

### Decision question

Should `Eta_test` expose one deterministic `Run.run` entry point whose outcome
contains the program exit and all test-observable execution evidence, and can
fiber/finalizer accounting be added without any production-runtime cost?

### Non-negotiable proof obligations

| ID | Proof question | Evidence required | Risk | Initial status |
| --- | --- | --- | --- | --- |
| P1 | Can one call collect exit, logs, spans, metrics, and ordered virtual sleeps? | Public `.mli`, focused tests, W6 fixture | Medium | Pending |
| P2 | Can pending fibers distinguish runtime-owned daemons from leaked structured work? | Test-only registry, daemon red-team fixture | High | Pending |
| P3 | Can finalizer success/failure and execution order be journaled without changing production execution? | Contract-level test instrumentation and neutrality proof | High | Pending |
| P4 | Is the complete outcome deterministic for identical programs and runtime construction? | Replay tests across the six canonical scenarios | High | Pending |
| P5 | Does one golden failure remain actionable at six-scenario corpus size? | Broken retry fixture and captured Alcotest output | High | Pending |

### Hypothesis space

| Candidate | Steelman | Evidence needed to win | Falsifier | Status |
| --- | --- | --- | --- | --- |
| A. Golden record plus test-only accounting | One runtime-owned observation boundary can expose lifecycle facts users otherwise assemble incorrectly. | Six scenarios, neutrality, readable printer, zero production-path accounting | Accounting changes production cost/semantics or printer is unreadable | Favored, active |
| B. Golden record without accounting | Existing sinks and virtual time already remove most assembly while preserving the production runtime untouched. | Phase 1 and printer pass while accounting gate fails | Record cannot diagnose the required ordinary scenarios | Active fallback mandated by objective |
| C. Existing helpers only | Explicit assembly exposes all mechanics and adds no API. | Equal call-site burden and diagnostics to A/B | W6 and broken-output packet show material improvement | Baseline |
| D. Bespoke test interpreter | A dedicated interpreter could observe every operation directly. | Same semantics as production runtime with bounded implementation | Duplicates runtime semantics or bypasses E19 machinery | Disfavored; expected out of scope |

### Sealed predictions

These predictions are fixed before source changes and will be scored in the
final report.

1. **Phase 1 feasibility — pass (90%).** `Run.run` can compose a fresh
   `Test_clock`, in-memory logger/tracer/meter, seeded random source, and E19
   scoped overrides while returning a single record. No new production
   dependency or application environment is needed.
2. **Automatic virtual-time driving — pass with one test-only clock seam
   (75%).** A synchronous one-call runner will need to observe the next queued
   sleeper and advance the existing `Test_clock`; requested durations can be
   recorded in insertion order without changing existing manual-clock behavior.
3. **Fiber accounting — partial/pass (60%).** A decorated test runtime contract
   can assign deterministic IDs and track structured and daemon fibers without
   adding fields, branches, or callbacks to the production runtime. Runtime-owned
   daemons will be reported as owned pending work, not automatically labeled
   leaks.
4. **Finalizer accounting — highest-risk partial (40%).** The contract-level
   `protect` seam will be insufficient by itself to identify every individual
   finalizer and its result. A test-only hook may be possible at finalizer
   registration/execution without changing the production path; otherwise this
   field must be killed or narrowed rather than adding an optional production
   callback.
5. **Accounting neutrality — pass if accounting ships (80%).** Running the same
   corpus with ordinary and accounting runtimes will preserve exits exactly;
   ordering metadata will be observational only. Any exit difference kills the
   accounting implementation.
6. **Canonical scenarios — 6/6 executable (75%).** Existing `par`, resource,
   retry, tracing, cause, and race semantics are sufficient. The interruption
   scenario may require a deterministic concurrent driver but no production API.
7. **Golden printer — promote (80%).** A sectioned printer with exit first,
   ordered events second, and pending fibers last will satisfy the
   what/where/what-next rubric. Six outcomes should remain scannable if empty
   sections are compact and event entries are one logical line each.
8. **Public census (70%).** The shipped public surface will stay within one
   `Run` module, one outcome record, two accounting record types, three
   expectation helpers, `pp`, and Alcotest testable construction; no changes to
   `Schedule.t`, E19/E20 APIs, or production packages.

### Diagnostic evidence order

1. Probe whether contract decoration can account for fibers and individual
   finalizers with literally no production-runtime edit.
2. Build the minimal Phase 1 vertical slice and virtual-time driver.
3. Prove accounting neutrality before polishing the accounting API.
4. Run the broken retry output before accepting the printer design.
5. Run all six scenarios twice before claiming determinism.

### Constraints and explicit non-goals

- `Eta_test` only; applications continue to own state.
- No production runtime accounting branch, callback, service lookup, or field.
- No compatibility path, fallback runtime behavior, `Schedule.t` change, or
  edits to E19/E20 machinery.
- A failed accounting proof does not kill the Phase 1 record.
- A corpus-unreadable printer kills the whole proposal.

### What would change the favored decision

- Any measured or structural production-path accounting cost selects candidate
  B for accounting fields.
- Any mismatch between ordinary and accounting exits rejects accounting.
- Broken golden output that does not identify expected versus observed sleeps
  and the scenario location rejects the printer and therefore the whole E11
  proposal.

## V-DX-E11-002 — accounting feasibility verdict

Status: **PARTIAL — fiber accounting accepted; finalizer journal killed**

### Evidence

- `Runtime_contract.RUNTIME.fork` and `fork_daemon` are public backend contract
  operations. `Eta_test` can decorate the Eio test backend, assign local
  deterministic IDs, and remove entries when callbacks settle. This requires no
  edit to `Runtime_core.t`, `Effect_core.frame`, or any production runtime path.
- `Effect_core.frame.finalizers` is a private `(unit -> unit) list ref`.
  `Runtime_core.run_finalizers` directly invokes every closure inside one
  `Runtime_contract.protect` callback and collapses failures into one cause tree.
  There is no contract operation around an individual finalizer.
- `protect` cannot stand in for a finalizer event: it wraps the whole batch and
  is also used by channel, queue, pool, pubsub, semaphore, concurrency, and
  uninterruptible paths. Treating it as a finalizer would produce false events,
  lose per-finalizer order, and fail to distinguish success/failure per item.
- Existing `Cause.Finalizer` and `Cause.Suppressed` values preserve aggregate
  finalizer failures in `Exit.t`, but successful finalizers leave no runtime
  diagnostic and therefore cannot be reconstructed from the exit.

### Decision

- **Accept** test-only fiber accounting by contract decoration.
- **Kill** `finalizer_events` and `expect_finalizers`. Do not expose an
  always-empty field and do not infer events from `protect`.
- Canonical finalizer scenarios remain executable: failed finalizers are visible
  in `outcome.exit`; successful finalizer effects can emit ordinary recorded
  logs/metrics for scenario evidence. This is not represented as runtime
  finalizer accounting.

### Counterevidence considered

A production callback in `run_finalizers` would provide exact events, but it
would add a branch/callback to every production finalizer batch and violates the
assignment's zero-cost and scope fences. Copying the private interpreter into
`eta_test` would duplicate runtime semantics and violate the requirement to
compose the existing runtime.

### Confidence and change condition

Confidence: **High**, because the individual closure invocation is visible in
the private implementation and absent from the complete public contract.
Reconsider only if the production runtime independently acquires a zero-cost
compile-time accounting specialization or a per-finalizer contract trampoline.
