# DX-E19 teach-back

1. **Where does the fake clock stop applying?**

2. **A `par` sibling needs the same fake clock — what do you write?**

## Reviewer key

1. It applies to leaves called in the dynamic subtree and to children that
   inherit it at fork. It does not retroactively alter an already-started sleep
   or span. A daemon forked inside keeps it even after the lexical scope exits.
2. Wrap the whole `Effect.par left right` with one `Effect.with_clock`, or wrap
   both branches separately. An override inside only one branch is isolated
   from its sibling.
