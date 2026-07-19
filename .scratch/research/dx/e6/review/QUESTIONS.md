# DX-E6 Independent Review Questions

For each snippet, answer without consulting implementation code:

1. Second acquire fails — what happens?
2. Which release runs first at scope exit?
3. Are acquisitions sequential?
4. Rate the lifecycle call site from 1 (hard to scan) to 5 (immediately clear).
5. Which snippet would you choose for three independent resources, and why?

## Screenshot test

View each complete snippet at the same font size and editor width. Record:

- maximum nesting depth needed to follow the bootstrap;
- distinct lifecycle/concurrency concepts visibly named at the call site;
- whether all three peer resources fit in one visual scan;
- whether acquire/release pairing is recoverable without jumping across levels.

The kill gate is mechanical: if `boot-new.ml`'s labelled boilerplate rates worse
than `boot-old.ml`, kill `with_2`/`with_3` and keep only the arity-greater-than-3
recipe.
