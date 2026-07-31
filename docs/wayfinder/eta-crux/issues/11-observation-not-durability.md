# Observation reflects committed state, not durability

Type: grilling
Status: open

## Question

A tick commits state, settles, runs lifecycle, observes outputs, then spawns commands. So an
observer necessarily sees a transition before the command that persists it has even started.
Nothing in the notes says this.

Every application with durable state, and every application that suppresses a notification
after recording it, will assume that observation implies durability. The correct answer is
the Elm one: encode the distinction in the model, as saving versus saved, and let the command
report completion as an action. But if it goes unstated, each client discovers it through a
data-loss bug. It must be an explicit idiom rather than a framework barrier, because gating
observation on effect completion would make a tick's duration depend on I/O.

Decide:

- That output observation reflects committed state and implies nothing about the completion
  of any command scheduled by the same transition.
- That an application distinguishing durable state represents that distinction in the model,
  updated by the action that reports command completion.
- That no command class exists whose completion gates output observation.
