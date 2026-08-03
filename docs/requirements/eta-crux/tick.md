---
kind: requirement
tags: [eta_crux, tick, stabilization, scheduling, eta_signal]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/core-loop]]", "[[docs/requirements/eta-crux/fragments]]"]
traces_to: ["[[docs/prds/0002-eta-signal-frp]]"]
---
# Tick and stabilization scheduling

## Intent

A tick is one driver advancement of Eta Crux ready work. During a tick, Eta Crux
processes ready actions and due timers, commits model changes, stabilizes the
computation graph, runs lifecycle changes revealed by stabilization, exposes
changed outputs, and starts work from staged scheduled commands.

Action processing is separated from effect execution. A cell transition runs at
most once for each processed action. The transition returns a new model and
scheduled commands. Eta Crux commits the new model before it exposes a later
stabilized result. It starts command work from scheduled commands only after
observation for the tick.

Graph stabilization is the only phase that makes derived computation values,
dynamic structure, lifecycle changes, and exposed fragments visible. Eta Crux
does not expose a partially applied action batch.

Input-dependent cells require a freshness rule for graph input during action
processing. That rule is not yet settled; see open questions.

## Requirements

- When a tick begins, eta_crux shall drain the currently available queued actions
  up to the configured batch limit. ^tick-3k9p
- When eta_crux processes an enqueued action for a state-machine cell, eta_crux
  shall call that cell's transition function exactly once with the cell's
  current model and the action. ^tick-5h8x
- When a state-machine cell transition returns a new model, eta_crux shall replace
  that cell's stored model before exposing the next stabilized computation
  result. ^tick-4m2d
- When a transition returns scheduled commands, eta_crux shall stage those
  scheduled commands only after committing the returned model. ^tick-7v5d
- When a tick processes a batch containing only actions for cells whose
  transitions do not require graph input, eta_crux shall stabilize the graph
  after all actions in that batch have been processed. ^tick-9w4x
- When stabilization changes the live structure, eta_crux shall run scope
  deactivations before scope activations and shall run lifecycle work before
  observing fragments. ^tick-c7m4
- When a tick has pending scheduled commands, eta_crux shall start their command
  work after fragment observation and shall enqueue their result actions for a
  later tick. ^tick-e1v6
- When graph stabilization is in progress and eta_crux receives an action from
  dispatch, command work, or a subscription item, eta_crux shall enqueue
  that action for a later tick. ^tick-2n7q
- While graph stabilization is in progress, eta_crux shall perform no cell model
  commit. ^tick-r8m4
- While no tick is in progress, an observed computation result or fragment shall
  reflect a fully stabilized graph state. ^tick-6d3j
- When the inbound queue transitions from empty to non-empty, eta_crux shall make
  the application driver eligible to advance. ^tick-5r8w
- When a timer deadline becomes due, eta_crux shall make the application driver
  eligible to advance. ^tick-k9r2
- Where a maximum batch size is configured, eta_crux shall process at most that
  many queued actions in one tick and leave the remaining actions queued for a
  later tick. ^tick-f8h2

## Open questions

- For input-dependent cells, should eta_crux stabilize before processing an
  action when an earlier action in the same drained batch invalidated that
  cell's graph input, or should the transition receive the previous stabilized
  input value for that tick?
- Whether `max_batch` is a global driver setting or per application instance.
- Whether a tick that produces only cutoff-suppressed fragment changes should
  notify any push subscriber for liveness.
