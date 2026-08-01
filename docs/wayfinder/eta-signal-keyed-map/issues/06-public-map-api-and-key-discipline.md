# Public map API and key discipline

Type: prototype
Blocked by: 05

## Question

What exact `Eta_signal_map.Map` API gives applications normal map operations
without publishing a collection framework?

Prototype the strongest key-discipline candidates:

- a `Map.Make`-style functor over an ordered key module
- a first-class comparator witness carried by each map

Use one Taumel-shaped producer and one downstream keyed-composition example.
Compare inferred types, error messages, module plumbing, and output-map
construction.

Decide the minimum V1 operations. Cover construction, lookup, persistent edit,
ordered traversal, cardinality, equality, and symmetric diff. State duplicate
key behavior for every bulk constructor.

Decide whether `fold_symmetric_diff` accepts `data_equal` or reports all
physically changed values. The API must not permit a false equality function to
hide a real update silently.

Specify which transforms preserve ancestry when their output data remains
physically equal. Document which constructors and conversions sever ancestry.

Keep the prototype on a throwaway branch. Link its sketches and commit from the
answer.
