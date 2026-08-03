---
kind: requirement
tags: [eta_crux, errors, crash, defects, cause]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/commands-and-effects]]", "[[docs/requirements/eta-crux/tick]]"]
traces_to: []
---
# Error and crash boundary

## Intent

Expected failures are application values. Command work and subscription sources
fold typed failures into actions before they reach Eta Crux as scheduled work.

Defects are fatal to the application instance. This rule includes defects in
transitions, init work, command work, subscription sources, lifecycle operations,
and resource release.

The crash path captures an Eta `Cause` and crash context, invokes the
application crash handler, and then runs ordered teardown. Model data appears in
the crash report only for cells that provide an explicit snapshot hook.

Crash rendering belongs to adapters or host code. Eta Crux emits a crash report;
it does not render UI.

## Requirements

- When command work or a subscription source produces a typed failure, eta_crux
  shall receive that failure only as an action produced by application error
  folding. ^err-4k9t
- If a defect occurs in a transition, init work, command work, subscription
  source, lifecycle operation, or resource release, then eta_crux shall treat the
  defect as fatal to the application instance. ^err-7m2p
- If a fatal defect occurs, then eta_crux shall capture the Eta `Cause`,
  originating cell identity, trigger kind, and triggering action when a
  triggering action is available. ^err-9x3w
- If a fatal defect occurs in a cell with a model snapshot hook, then eta_crux
  shall include the redacted model snapshot produced by that hook in the crash
  report. ^err-k4m9
- If a fatal defect occurs in a cell without a model snapshot hook, then eta_crux
  shall omit that cell's model data from the crash report. ^err-v6p1
- If a fatal defect occurs, then eta_crux shall tear down cleanly by closing
  action admission, disposing the graph, interrupting in-flight command work and
  subscription sources, releasing managed resources, and stopping observers. ^err-b6n1
- While an application instance is in a crashed state, eta_crux shall reject new
  action admission and shall not advance further application work. ^err-2h8v
- When eta_crux produces a crash report, eta_crux shall deliver the report to the
  configured crash-report handler. ^err-c5r4
- If the application crash handler raises, then eta_crux shall fall back to a
  built-in minimal crash report and shall not invoke the application crash
  handler again for the same fatal defect. ^err-e1t7
- If a fatal defect occurs, then eta_crux shall provide no automatic cell-level
  restart. ^err-8w2k

## Open questions

- Exact stable fields of the crash report.
- Whether the crash report is delivered through a terminal callback, an output
  fragment, or both.
