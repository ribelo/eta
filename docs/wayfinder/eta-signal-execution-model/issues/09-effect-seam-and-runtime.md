# Effect seam and Eta runtime

Type: prototype
Status: resolved
Blocked by: 03, 06, 07, 08

## Question

Which effect seam preserves cancellation, concurrency, typed failures, and
runtime ownership at the lowest measured adapter cost?

Compare all approved boundaries around the same kernel. Identify whether Signal
needs a small general Eta runtime primitive, and state that primitive's
motivating invariant.

## Answer

Use one private serialized execution driver around synchronous kernel work.

The driver gets the active Eta runtime during interpretation. It owns graph-lane
acquisition, owner-domain checks, same-fiber reentry, queued cancellation, and
Eta cause conversion.

The kernel receives one cancellation checkpoint. It calls this checkpoint
immediately before publication, so interruption uses the normal sparse rollback
path.

Keep post-commit claims opaque. Reject explicit edge cursors as the adapter seam
because they expose claim and acknowledgement order and add 240 words in the
crossing probe.

The selected driver adds 96 words above Effect. Separate public operations add
98 words, and Eio adds 283 words. All adapter rows pass their ceilings and stay
independent of graph depth.

The queued-cancellation candidate allocates 1,509 words against 6,911 words for
the pinned Eta reference. Its largest wall-time ratio is 0.253.

Add no general Eta runtime primitive. The existing runtime contract already
supplies promises, protection, cancellation checks, fiber identity, and locals.

Its motivating invariant is commit-before-wake. Queue state commits before
promise resolution, and wake notification does not run Eta code on the resolving
domain.

The interfaces, Design It Twice comparison, semantic evidence, measurements,
and limits are in
[Effect seam and Eta runtime](../../../../.scratch/research/eta-signal-execution-model/effect-seam-and-runtime.md).
