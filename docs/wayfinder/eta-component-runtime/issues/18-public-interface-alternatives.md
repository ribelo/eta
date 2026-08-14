# Public interface alternatives

Type: prototype
Status: claimed
Blocked by: 09, 10, 11, 12, 13, 14, 15, 16, 17, 23

## Question

Which public interface gives Eta the deepest component, context, coeffect,
loader, and HMR modules?

Produce several materially different OCaml interface sketches. Include one
ordinary-value design, one typed declarative design, and the strongest viable
phantom-indexed design from the typed-key prototype.

Compare interface size, compiler errors, inference, separate compilation,
portability, testing, and how much lifecycle knowledge callers must retain.
Use the deletion test and select no interface until the user has reviewed the
alternatives.

## Prototype for review

The comparison prototype is on branch
`prototype/eta-component-public-interface-alternatives` at commit `46077cc0`.
See the
[prototype source](https://github.com/ribelo/eta/tree/46077cc0a51ffe355212e35f93f62ce7367109f3/.scratch/eta-component-runtime-public-interface)
and its
[comparison](https://github.com/ribelo/eta/blob/46077cc0a51ffe355212e35f93f62ce7367109f3/.scratch/eta-component-runtime-public-interface/COMPARISON.md).

The prototype contains three compiling interface sketches:

- Ordinary values with runtime declaration checks.
- Typed requirement and provision schemas.
- Generative modules with declaration rows and context phantoms.

The provisional recommendation prefers typed schemas without public row or
context indices. It keeps explicit context operations and a native-only HMR
adapter seam. This recommendation is not selected.

A high-tier review found no remaining material fault. The review verdict was
`ready for human review`.
