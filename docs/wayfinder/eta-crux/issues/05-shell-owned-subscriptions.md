# Shell-owned subscriptions

Type: grilling
Status: open
Blocked by: 04

## Question

Subscription sources are Eta streams inside the core. A shell-owned stream has no shape: a
start capability message goes out, a stop capability message goes out, and items arrive as
unrelated inbound actions. So the desired-set reconciliation that makes subscriptions
correct does not apply to any source the shell owns.

This is the dominant case for a host-embedded core: child-agent lifecycle events and
exec-process output originate on the host side. Leaving them outside subscriptions makes
start and stop manual, keeps "which sources should be running" out of the model, and makes
a stop racing an in-flight item application-visible. This is where lost-terminal-event bugs
live. In Elm this is an effect manager over a port; in Crux it is `RequestHandle::Many`.

Decide:

- Whether a shell-owned subscription reconciles its desired presence from committed state
  exactly as a core-owned one does.
- Start emission when it enters the desired set, and stop emission when it leaves the set or
  its owning scope is disposed.
- Item admission through the same producer path as core-owned subscription items.
- Discarding an item that arrives for a source no longer in the desired set, running no
  transition.
- Typed failures folding into actions, while a shell-reported defect reaches the crash
  boundary.
- Whether the mechanism is the Many-semantics handle from ticket 04 or a separate concept.
