# Eta Signal extension seam

Type: prototype
Blocked by: 05, 06

## Question

What minimum Eta Signal capability lets `eta_signal_map` install one
transactional keyed node without exposing general graph internals?

The current graph, scope, bind, and transaction modules are private to the
`eta_signal` library. A sibling library cannot call them directly. Prototype the
smallest package and module seam that solves this constraint without a circular
dependency.

Show how the seam supports:

- one graph instance and its generative signal type
- provisional keyed scopes and stable per-key data sources
- dependency attachment and removal
- preflight, commit, and rollback of structural edits
- removal before addition during commit
- scope invalidation and stale-incarnation rejection
- demand and observer reachability

The public `Eta_signal` facade must not gain a graph value, scope handle, raw
node constructor, or broad `Expert` module.

Compare an internal capability module, a shared kernel library, and a narrow
extension functor. Include Dune dependency sketches and negative type examples.

Keep the prototype on a throwaway branch. Link its sketches and commit from the
answer.
