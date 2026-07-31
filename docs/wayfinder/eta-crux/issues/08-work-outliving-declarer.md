# Ownership of work that outlives its declarer

Type: grilling
Status: open
Blocked by: 01

## Question

In-flight commands are interrupted when their owning cell's scope is disposed, and a
deselected branch disposes its cells. Nothing states where work belongs when it must survive
the disappearance of the thing that logically declared it.

eta_crux is stricter than both references here, and correctly so: in Elm a command in flight
always delivers, so the question never arises. But the natural first modelling — "the
session owns its child runs" — silently kills work that must keep running when the session's
view goes away. A live child agent must keep running after its parent host session is
unloaded.

Decide:

- The idiom: work is owned by a cell whose lifetime matches the work's lifetime, addressed
  by the work's own identity, rather than by the cell that happened to request it.
- Whether any mechanism detaches in-flight command or subscription work from its owning
  scope. The proposal is that none exists.
- That a cell displaying work owned elsewhere reads values rather than taking ownership.

Depends on ticket 01 because "addressed in a keyed collection" is a graph-backend concept.
Under a static-structure plain backend the idiom must be expressible without keyed cells,
or the ticket must say that this pattern requires the graph backend.
