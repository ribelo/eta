# Startup flags

Type: grilling
Status: open

## Question

Construction installs each cell's initial model and activation stages its init commands,
but nothing carries host-supplied startup configuration. Elm has `init : flags -> (Model,
Cmd Msg)` for exactly this purpose.

A host-embedded core always has startup facts that are neither compile-time constants nor
actions: owner session id, working directory, resolved paths, model and thinking settings,
feature flags. Without flags an application either captures them in the root-construction
closure — which makes that closure the real API and defeats testability — or invents a
synthetic initialize action whose absence is unrepresentable.

Decide:

- Whether an application instance accepts typed flags and passes them to the
  root-construction function.
- Whether a cell's initial-model computation can read flags.
- Whether flags are immutable for the life of the instance, with no replace operation.
- How flags reach the test harnesses, which must supply them to construct an instance.
