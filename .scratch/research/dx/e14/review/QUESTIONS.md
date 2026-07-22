# DX-E14 Promise Teach-back

## Questions

1. What happens to a cancelled waiter?
2. Who can resolve a promise?
3. What does the second resolve return?
4. Does one waiter consume the result?
5. What happens if every current waiter's scope closes before resolution?

## Answer key

1. Ordinary Eta cancellation interrupts it and removes it without consuming the
   result. Other and later waiters remain able to observe resolution.
2. Any fiber holding the promise can attempt `resolve`; resolver authority is
   not split into a separate public handle.
3. `false`. The first attempt returns `true` and permanently preserves its full
   `Exit.t`.
4. No. Every current waiter wakes, and a later `await` observes the same exit
   immediately.
5. The cancelled waiters are removed, but the cell is not closed with their
   scopes. A later first resolution still returns `true` and is observable by a
   later awaiter.
