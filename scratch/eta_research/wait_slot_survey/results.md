# Wait Slot Survey Results

## Question

Should Eta extract a public Eta.Wait_slot, or should the wait protocol stay
inside Eta.Pool for now?

The pool-survival lab needed waiter registration, cancellation cleanup,
normal-vs-cancelled accounting, and retry wakeups. The question is whether that
surface is itself the public primitive.

## Cross-Tab

| Consumer | Needs raw waiter registration? | Needs cancellation cleanup? | Better primitive |
| --- | --- | --- | --- |
| Eta.Pool acquire | Yes internally. | Yes, cancelled waiters must not occupy capacity and must update stats. | Inline Pool wait queue. |
| eta-http request/response correlation | No. It needs request id to response wakeup and close/error propagation. | Yes. | Channel or promise-like map owned by eta-http. |
| eta-grpc call admission | No. It admits streams/calls by integer capacity. | Yes. | Permit_set / Channel. |
| eta-sql query queue | Not outside Pool. Queries wait for a connection checkout. | Yes. | Eta.Pool acquire. |
| HTTP/2 stream admission | No. It waits for stream permits, not connection values. | Yes. | Permit_set. |
| Bounded channel send-when-full | No as a public API. The caller wants send/recv/close semantics. | Yes. | Eta.Channel. |
| Future Cohort_map quota waits | No initially. Waiting is over key budget or child pool acquire. | Yes. | Cohort_map + Pool/Permit_set internals. |

## Verdict

Inline for Eta-t59. Do not expose Eta.Wait_slot as a public primitive yet.

The exact pool wait-slot protocol is reusable as implementation technique, but
every surveyed public consumer wants a richer domain primitive:

- Pool acquire/release
- Channel send/recv/close
- Permit_set acquire/release
- keyed Cohort_map lookup/acquire

Publishing Wait_slot now would expose a low-level synchronization protocol
without a proven direct user. It would also risk freezing cancellation and stats
semantics before Channel and Permit_set settle their own APIs.

## Eta-t59 Direction

Eta.Pool should own a private wait queue with these invariants:

- registering a waiter is paired with finalizer cleanup
- cancelling while queued removes the waiter exactly once
- cancelling after wakeup does not lose the acquired permit/slot
- stats distinguish waiting from cancelled_waiters
- caller-visible cancellation remains typed after the G1 runtime fix

The private code should be small and named clearly enough that Channel or
Permit_set can reuse the idea later by extraction, not copy/paste.

## Reopen Criteria

Reopen public Eta.Wait_slot only if at least two shipped Eta primitives need the
same lower-level surface after implementation, not just the same idea.

Concrete evidence that reopens:

- Eta.Pool and Eta.Channel both contain near-identical waiter data structures
  and cancellation finalizers.
- Permit_set needs a wait operation that cannot be expressed cleanly as acquire.
- Cohort_map needs cross-cohort waiting that is neither Pool acquire nor
  Permit_set acquire.

Until then, Wait_slot is an implementation detail.
