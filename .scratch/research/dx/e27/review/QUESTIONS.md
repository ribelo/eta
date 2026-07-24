# DX-E27 review questions

1. **When does the format run?**
   Once, while the effect is running, after logging is enabled and the scoped
   minimum admits the level. It does not run while the blueprint is built or
   for a disabled/filtered record. An interceptor may still `Drop` the formed
   record after formatting.
2. **What about the arguments?**
   They are ordinary eager OCaml arguments. In
   `Effect.logf "len %d" (Queue.length q)`, `Queue.length q` runs while the
   blueprint is built; only application of the captured format is deferred.
