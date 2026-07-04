---
kind: requirement
status: draft
tags: [eta_crux, commands, effects, errors]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/core-loop]]"]
traces_to: []
---
# Commands and effects

## Intent

Command work is a force-total Eta effect that resolves to an action. A scheduled
command is command work plus Eta Crux execution metadata. The metadata records
the owning cell scope, the emission order for test handles, and the command slot
when the application schedules the command in a slot.

Cell transitions do not perform effects inline. They return a list of scheduled
commands. Eta Crux commits the returned model during action processing, then
starts the staged command work during the command-spawn phase.

Typed command failures are folded into actions before work is scheduled. Defects
are not typed failures; a defect in command work crosses the crash boundary.
Interruption from scope disposal or slot replacement produces no result action.

Sibling commands from one transition run concurrently as independent Eta fibers
under the owning cell scope. Sequencing is expressed inside one command by
composing Eta effects.

Command diagnostics use Eta effect names and annotations. Eta Crux does not add
a separate framework-level command name or argument payload.

## Requirements

- **cmd-4t7m** (ubiquitous): When application code defines command work,
  eta_crux shall require the work to be a force-total Eta effect that resolves
  to an action.
- **cmd-t3w8** (ubiquitous): When command work can fail with a typed error,
  eta_crux shall require application code to fold that error into an action
  before the work is scheduled.
- **cmd-j2p6** (ubiquitous): When application code schedules command work,
  eta_crux shall represent the scheduled command as the command work plus
  execution metadata.
- **cmd-l8n3** (event-driven): When eta_crux stages a scheduled command,
  eta_crux shall record the owning cell scope and emission order in the
  command's execution metadata.
- **cmd-s4h8** (event-driven): When application code schedules a command in a
  slot, eta_crux shall interpret that slot within the owning cell's command
  scope and shall record the slot in the command's execution metadata.
- **cmd-n2b7** (ubiquitous): When a state-machine transition returns work to run
  later, eta_crux shall receive that work as a list of scheduled commands.
- **cmd-e2r9** (event-driven): When eta_crux evaluates a state-machine
  transition, eta_crux shall not run command work during transition evaluation.
- **cmd-b3n6** (event-driven): When eta_crux starts command work, eta_crux shall
  run it as an Eta fiber owned by the command's cell scope.
- **cmd-6k3w** (event-driven): When one transition returns multiple scheduled
  commands, eta_crux shall run their command work concurrently as independent
  Eta fibers.
- **cmd-9d2t** (ubiquitous): When application code needs ordering between side
  effects, eta_crux shall require that ordering to be expressed by composing the
  effects inside one command.
- **cmd-1s6k** (event-driven): When command work completes successfully,
  eta_crux shall enqueue exactly one result action for the owning cell.
- **cmd-r6m2** (event-driven): When eta_crux starts a command in an occupied
  slot, eta_crux shall interrupt the previous command in that slot before
  registering the new command as current.
- **cmd-v9k1** (event-driven): When a slotted command completes, eta_crux shall
  clear the slot only if the completing command is still current for that slot.
- **cmd-p3n7** (event-driven): When a cell scope is disposed, eta_crux shall
  interrupt all in-flight commands owned by that cell, including slotted and
  unslotted commands.
- **cmd-d8w5** (event-driven): When a command is interrupted by slot replacement
  or scope disposal, eta_crux shall produce no result action for that command.
- **cmd-7h2q** (ubiquitous): When command work is scheduled, eta_crux shall keep
  the effect value inside the OCaml core and shall not serialize or forward that
  effect across an adapter boundary.
- **cmd-r5w9** (ubiquitous): When eta_crux records command diagnostics,
  eta_crux shall use Eta effect names and annotations and shall not require a
  separate framework command name or argument payload.
- **cmd-b8v1** (ubiquitous): When a transition returns a finite command list,
  eta_crux shall impose no framework-level concurrency cap on that list.

## Open questions

- Exact public constructors for scheduled commands, including the slot API and
  emission-order exposure in `eta_crux_test`.
