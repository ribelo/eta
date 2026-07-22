# DX-E13 Cancellation Teach-back

## Questions

1. When does the optional canceler run?
2. How many times can it run?
3. Can it run after a callback resolution wins?
4. What happens when the callback is called twice?
5. May a canceler block indefinitely?

## Answer key

1. Only when runtime interruption wins while the async registration is still
   pending. It does not run for success, typed failure, or a registration defect.
2. At most once, under cancellation protection.
3. No. Resolution and interruption compete for one atomic pending state;
   resolved state permanently excludes the canceler.
4. The first `Exit.t` is retained. Every later callback call is dropped and
   returns normally.
5. No. Eta waits for protected host cleanup, so a non-terminating canceler makes
   interruption wait forever. Eta does not add a hidden timeout or detach.
