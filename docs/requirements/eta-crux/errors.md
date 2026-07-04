---
kind: requirement
status: draft
tags: [eta_crux, errors, crash, defects, cause]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/commands-and-effects]]", "[[docs/requirements/eta-crux/tick]]"]
traces_to: []
---
# Error and crash boundary

## Intent

Expected failures are application values. Command work and subscription sources
fold typed failures into actions before they reach Eta Crux as scheduled work.

Defects are fatal to the application instance. A defect in a transition, init
work, command fiber, subscription source, lifecycle operation, or resource
release stops the instance through the crash path.

The crash path captures an Eta `Cause` and crash context, invokes the
application crash handler, and then runs ordered teardown. Model data appears in
the crash report only for cells that provide an explicit snapshot hook.

Crash rendering belongs to adapters or host code. Eta Crux emits a crash report;
it does not render UI.

## Requirements

- **err-4k9t** (event-driven): When command work or a subscription source
  produces a typed failure, eta_crux shall receive that failure only as an action
  produced by application error folding.
- **err-7m2p** (event-driven): When a defect occurs in a transition, init work,
  command fiber, subscription source, lifecycle operation, or resource release,
  eta_crux shall treat the defect as fatal to the application instance.
- **err-9x3w** (event-driven): When a fatal defect occurs, eta_crux shall
  capture the Eta `Cause`, originating cell identity, trigger kind, and
  triggering action when a triggering action is available.
- **err-k4m9** (event-driven): When a fatal defect occurs in a cell with a model
  snapshot hook, eta_crux shall include the redacted model snapshot produced by
  that hook in the crash report.
- **err-v6p1** (event-driven): When a fatal defect occurs in a cell without a
  model snapshot hook, eta_crux shall omit that cell's model data from the crash
  report.
- **err-b6n1** (event-driven): When a fatal defect occurs, eta_crux shall tear
  down cleanly by closing action admission, disposing the graph, interrupting
  in-flight commands and subscriptions, releasing managed resources, and
  stopping observers.
- **err-2h8v** (state-driven): While an application instance is in a crashed
  state, eta_crux shall reject new action admission and shall not advance further
  application work.
- **err-c5r4** (event-driven): When eta_crux produces a crash report, eta_crux
  shall deliver the report to the configured crash-report handler.
- **err-e1t7** (event-driven): When the application crash handler raises,
  eta_crux shall fall back to a built-in minimal crash report and shall not
  invoke the application crash handler again for the same fatal defect.
- **err-8w2k** (ubiquitous): When eta_crux handles a fatal defect, eta_crux
  shall provide no automatic cell-level restart.

## Open questions

- Exact stable fields of the crash report.
- Whether the crash report is delivered through a terminal callback, an output
  fragment, or both.
