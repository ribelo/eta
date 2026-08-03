---
kind: requirement
tags: [eta_crux, commands, effects, errors]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/core-loop]]"]
traces_to: []
---
# Commands and effects

## Intent

Command work is a force-total Eta effect that resolves to an action. A scheduled
command contains command work and Eta Crux execution metadata. The metadata
records the owning cell scope, the emission order for test handles, and an
optional command slot.

Cell transitions do not perform effects inline. They return a list of scheduled
commands. Eta Crux commits the returned model during action processing. Then it
starts work from the staged scheduled commands.

Typed failures from command work are folded into actions before scheduling. Defects
are not typed failures. A defect in command work crosses the crash boundary.
Interruption from scope disposal or slot replacement produces no result action.

Sibling scheduled commands from one transition run concurrently as independent
Eta fibers under the owning cell scope. Eta effect composition forms one command
work value when effects must run in sequence.

Diagnostics for command work use Eta effect names and annotations. Eta Crux does
not add a separate framework-level scheduled-command name or argument payload.

## Requirements

- When application code defines command work, eta_crux shall require the work to
  be a force-total Eta effect that resolves to an action. ^cmd-4t7m
- When command work can fail with a typed error, eta_crux shall require
  application code to fold that error into an action before the work is
  scheduled. ^cmd-t3w8
- When application code schedules command work, eta_crux shall create a
  scheduled command that contains the work and execution metadata. ^cmd-j2p6
- When eta_crux stages a scheduled command, eta_crux shall record the owning cell
  scope and emission order in that scheduled command's metadata. ^cmd-l8n3
- When application code schedules command work in a slot, eta_crux shall
  interpret that slot within the scope for scheduled commands owned by that cell
  and shall record the slot in the scheduled command's metadata. ^cmd-s4h8
- When a state-machine transition returns work to run later, eta_crux shall
  receive that work as a list of scheduled commands. ^cmd-n2b7
- When eta_crux evaluates a state-machine transition, eta_crux shall not run
  command work during transition evaluation. ^cmd-e2r9
- When eta_crux starts command work, eta_crux shall run it as an Eta fiber owned
  by the scheduled command's cell scope. ^cmd-b3n6
- When one transition returns multiple scheduled commands, eta_crux shall run
  their command work concurrently as independent Eta fibers. ^cmd-6k3w
- When application code needs ordering between side effects, eta_crux shall
  require application code to compose those effects as one command work value. ^cmd-9d2t
- When command work completes successfully, eta_crux shall enqueue exactly one
  result action for the owning cell. ^cmd-1s6k
- When eta_crux starts a scheduled command in an occupied slot, eta_crux shall
  interrupt the previous command work in that slot before registering the new
  scheduled command as current. ^cmd-r6m2
- When command work in a slot completes, eta_crux shall clear the slot only if
  its scheduled command is still current for that slot. ^cmd-v9k1
- When a cell scope is disposed, eta_crux shall interrupt all in-flight command
  work owned by that cell, including slotted and unslotted work. ^cmd-p3n7
- When command work is interrupted by slot replacement or scope disposal,
  eta_crux shall produce no result action for that work. ^cmd-d8w5
- When command work is scheduled, eta_crux shall keep the effect value inside the
  OCaml core and shall not serialize or forward that effect across an adapter
  boundary. ^cmd-7h2q
- When eta_crux records diagnostics for command work, eta_crux shall use Eta
  effect names and annotations and shall not require a separate scheduled-command
  name or argument payload. ^cmd-r5w9
- When a transition returns a finite list of scheduled commands, eta_crux shall
  impose no framework-level concurrency cap on that list. ^cmd-b8v1

## Open questions

- Exact public constructors for scheduled commands, including the slot API and
  emission-order exposure in `eta_crux_test`.
