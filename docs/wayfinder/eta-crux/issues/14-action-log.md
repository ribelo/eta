# Action log exposed to hosts

Type: grilling
Status: open

## Question

The test harnesses record actions and pending command handles, and the crash report captures
the triggering action, but a production host has no supported way to obtain the recent action
sequence.

Elm's debugger made the message log a first-class artifact, and it is the cheapest possible
diagnostic for a long-running host: on a crash or a stuck ask, the last N actions with cell
identity answer most questions. Rebuilding it per client means reaching into internals.

Decide:

- Whether an application can enable bounded action recording, retaining recent admitted
  actions with cell identity and tick sequence.
- Whether the crash report includes the retained record when recording is enabled.
- That no action history is retained while recording is disabled.
- Whether this is the same mechanism the test harnesses already use, or a separate
  host-facing one.
