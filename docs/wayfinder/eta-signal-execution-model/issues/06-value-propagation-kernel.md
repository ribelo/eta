# Value-propagation kernel prototype

Type: prototype
Status:
Blocked by: 02, 04, 05

## Question

Can a raw Eta kernel match Incremental for static value propagation while it
preserves Signal cutoffs, demand, ordering, and explicit stabilization?

Prototype in-place state, staleness tracking, and affected-parent scheduling.
Measure raw depth, fan-in, cutoff, and observer-free paths before adding an Eta
adapter.
