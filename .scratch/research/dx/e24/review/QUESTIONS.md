# Reviewer questions

Answer from the snippets and public names before consulting implementation code.

1. In `par-new.ml`, what does omitting `?max_concurrent` mean? Does it request
   unbounded concurrency, sequential work, or a default cap?
2. Does `Effect.map_par` return results in input order or completion order?
3. What does `~while_` decide, and what happens when it rejects the first typed
   failure?
4. What two values can the second argument of `~or_else` take, and what does each
   mean?
5. Can the retry fallback change the typed error from `source_error` to
   `final_error`?
6. Do the labeled retry shapes imply that `retry` and `retry_or_else` inspect
   composite causes identically?
