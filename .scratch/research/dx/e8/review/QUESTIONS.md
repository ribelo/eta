# Reviewer questions

1. What does the sugar add beyond `Effect.sync_result`?
2. Where does the span name come from?
3. What happens if the body raises?
4. Would you accept the expansion in `leaf-pair-hand.ml` as a verbatim PR
   rewrite of `leaf-pair-sugar.ml`?
5. In `heavy-after.ml`, is the remaining hand-written `sync`/`sync_result` on
   acquire/release still the right shape, or should those convert too?
