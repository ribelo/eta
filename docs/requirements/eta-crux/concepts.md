---
kind: doc
tags: [eta_crux, overview, concepts, mental-model]
---
# Concepts overview

This note defines the vocabulary used by the eta_crux requirement notes.

## Core Shape

Eta Crux applications are root computations made from state-machine cells.

```
inbound action
    |
    v
bounded action queue
    |
    v
driver advancement
    |
    +--> cell transition: input status -> model -> action -> model * scheduled-command list
    |
    +--> graph stabilization
    |
    +--> lifecycle work
    |
    +--> fragment observation
    |
    +--> command-work start
             |
             v
        Eta effect resolves to action
             |
             v
        bounded action queue
```

## Definitions

- **Application instance** — a live Eta Crux root computation with an internal
  graph, action admission, driver operations, output observation,
  scheduled-command and subscription ownership, and shutdown.
- **Root computation** — the top-level computation returned by the application's
  graph-construction function.
- **Cell** — a graph-native state-machine computation node with local model
  storage, a local action type, a transition function, lifecycle scope, result
  value, and inject function.
- **Model** — the application value owned by one cell. State remains the general
  term for runtime state or aggregate application state.
- **Read-only model value** — the computation value through which application
  code observes a cell model.
- **Action** — a typed event addressed to the cell that created the inject
  function used to emit it.
- **Inject function** — the cell-local function that admits actions for that
  cell.
- **Input status** — the value supplied to an input-dependent cell transition:
  either current input or inactive input status.
- **Scheduled command** — command work plus Eta Crux ownership, ordering, and
  replacement metadata.
- **Command work** — a force-total Eta effect that resolves to one action.
- **Command slot** — a per-cell replacement key for scheduled commands. A new
  scheduled command interrupts the current command work in that slot.
- **Subscription** — a state-derived long-lived Eta stream source whose items are
  mapped to actions.
- **Fragment** — one optional typed output value derived from a model or
  computation value and exposed at an address.
- **Output tree** — the aggregate of all live fragments in an application
  instance.
- **Startup input** — the reserved name for host-supplied startup data. Its type
  and lifecycle remain open.
- **Adapter** — host-specific code that submits inbound actions, observes
  fragments, and forwards outbound capability messages.
- **Message** — a boundary envelope or shell-capability value. A cell input is an
  action, not a message.
- **Capability message** — a typed outbound message asking an external shell to
  perform shell-owned work or stop shell-owned work.
- **Driver operation** — an explicit operation used by a host or test to submit
  actions, advance ready work, observe outputs, advance test time, or request
  shutdown.

## Elm correspondence

This table explains familiar roles. It does not define Elm compatibility or
require Elm-style OCaml identifiers.

| Eta Crux | Familiar analogue | Difference |
|---|---|---|
| Action | Elm `Msg` | An action addresses one cell. An Elm message enters one root update function. |
| Cell model | Elm `Model` | Each cell owns a model. Eta Crux has no required root-wide model. |
| Scheduled-command list | Elm `Cmd msg` | `[]` serves the role of `Cmd.none`. List construction and concatenation serve the role of `Cmd.batch`. Each scheduled command carries Eta Crux metadata. |
| Command work | Elm `Task x a` converted with `Task.attempt` | Typed failures become actions before scheduling. Eta defects and interruption keep Eta semantics. Eta effect composition serves the role of `Task.andThen`. |
| Subscription list | Elm `Sub msg` | `[]` serves the role of `Sub.none`. List construction and concatenation serve the role of `Sub.batch`. Eta Crux reconciles Eta stream sources by subscription identity. |
| Fragment and output tree | Rust Crux `ViewModel`, or an Elm `view` result | A fragment is one addressed output value. The output tree is the aggregate. |
| Startup input | Elm flags | The name is fixed. Its type and lifecycle remain open. |

## Analogy

A single-model framework is one waiter with one notebook. Eta Crux is a floor of
stations, and the floor plan itself follows the state.

| Eta Crux | Restaurant |
|---|---|
| Cell | A station with its own notebook and its own waiter |
| Root computation | The floor of stations, not one waiter with one pad |
| Graph-computed structure | The floor plan rearranges itself: a station appears when a party is seated and is struck when they leave |
| Computation value | The manager's live board, which totals every notebook |
| Action | "Table 3 asked for the check" |
| Cell transition | The station waiter hears it, updates that notebook, and may write slips |
| Command work | A slip to the kitchen. The slip is an ordinary Eta effect |
| Command slot | A station's spike: a new slip on the spike replaces the previous one |
| Fragment | The plates and the check the guest sees |
| Adapter | The pass: it plates kitchen output for this dining room |
| Capability message | An order to an outside supplier, plus the order to stand down |
| Subscription | A standing order, such as "keep coffee coming for table 5" |
| Driver operation | The expediter's calls: take orders, push work, read the pass, close the kitchen |
