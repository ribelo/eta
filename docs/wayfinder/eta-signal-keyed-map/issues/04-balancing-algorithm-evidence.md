# Balancing algorithm evidence

Type: research
Status: resolved
Blocked by: 01, 03

## Question

Which published tree algorithms and reference tests provide a credible basis
for Eta's clean-room map prototype?

## Answer

A persistent weight-balanced binary search tree provides the required edit
paths, ordering, and physical subtree sharing.

Nievergelt and Reingold define bounded-balance search trees. Hirai and Yamamoto
analyze valid balance parameters. The prototype starts with
`(delta, gamma) = (5/2, 3/2)` and decides their fit through invariant tests.

The symmetric diff uses two operations:

- recursive comparison of matching tree regions
- ordered enumeration when roots diverge

Both paths skip physically identical subtrees. Independent trees use a correct
ordered comparison without the ancestry-performance guarantee.

Eta writes the implementation from the papers. Base supplies behavioral cases,
reconstruction properties, and comparison-growth evidence. Eta does not copy
Base implementation or test code.

Research report:

- [Eta-owned design feasibility](../../../../.scratch/research/eta-signal-keyed-map/owned-design.md)
