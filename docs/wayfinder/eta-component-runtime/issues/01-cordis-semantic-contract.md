# Cordis semantic contract

Type: research
Status: resolved
Blocked by:

## Question

Which definitions, invariants, assumptions, and guarantees in the Cordis paper
form the transferable semantic contract for Eta?

Read the complete paper. Separate local temporal and spatial guarantees from
global lifecycle guarantees. Cover observational equivalence, independence,
withdrawal ordering, failure, progress, confluence, isolation, interception,
configuration reconciliation, and hot replacement.

For each guarantee, record its assumptions and observation boundary. Identify
paper mechanisms that are TypeScript realization choices rather than semantic
requirements. Record open problems and stated limits.

Write one cited report under
`.scratch/research/eta-component-runtime/`.

## Answer

The transferable contract is a component-runtime protocol for witnessed
recovery, typed provider views, guarded withdrawal, and convergent lifecycle
reconciliation. It requires explicit observational boundaries, effect
independence, acyclic dependencies, finite activation, and total provisions.
The TypeScript context object, proxy, generators, and module cache are
realization choices. See
[the cited report](../../../../.scratch/research/eta-component-runtime/01-cordis-semantic-contract.md).
