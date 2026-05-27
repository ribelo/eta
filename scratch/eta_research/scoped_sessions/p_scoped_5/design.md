# P-Scoped-5: External Background Fiber API Design

## Question

External Eta applications sometimes want daemon-shaped usefulness without daemon
ownership. The question is not WebSocket-specific:

- Keep raw daemon private.
- Make common background work easy enough that external users do not need daemon.
- Preserve structured lifetime and typed failure flow.

## Candidates

### A. Current Supervisor.scoped

Safe and already shipped, but exposes supervisor, Scope, rank-2 records, and
child start mechanics at every call site.

### B. Background.with_

Shape: val with_ : ?name:string -> (unit, 'err) Effect.t -> (unit -> ('a, 'err) Effect.t) -> ('a, 'err) Effect.t

This handles the most daemon-like external use case: run a background loop while
the foreground action executes, then cancel it.

### C. Fiber_scope.with_fiber

Shape: a small facade over Supervisor.scoped with an abstract scoped fiber, plus
lift, await, cancel, pure, bind.

This is still rank-2, but the user no longer receives the supervisor or calls
start. It is the smallest facade over Supervisor.scoped that supports explicit
await/cancel.

### D. Public daemon/start-return-handle

Rejected unless a future fixture proves it can preserve structured ownership.
Returning an externally storable handle is the capability that daemon provides
and Supervisor.scoped intentionally forbids.

## Evidence

- background_no_handle.ml: B expresses the no-handle background loop case.
- fiber_scope_with_handle.ml: C expresses explicit await on a started child.
- external_app_comparison.ml: B and C cover three external app stories:
  background loop, explicit await, explicit cancel.
- negative/fiber_scope_escape_negative.ml: C rejects returning the fiber handle.

## Surprise Finding

`Supervisor.Scope.cancel` is cancellation request, not stop-and-join. The
external_app_comparison fixture expected a child finalizer to have run after
`cancel fiber`, but the observed value was false:

`cancel: expected "true" got "false"`

This means a public external-facing fiber API should not expose only `cancel` if
the story is "stop this background worker, then continue after cleanup." It
needs an explicit operation with stronger semantics, for example:

- `stop : ('s, 'a, 'err) fiber -> ('s, unit, 'err) t`
- semantics: request cancellation, wait for the child to settle, treat pure
  interruption as successful stop, and propagate a pre-existing typed failure or
  defect.

This pass then prototyped `Supervisor.Scope.stop` with those semantics. It
cannot be expressed cleanly with the old public `cancel`/`await` pair because
`await` after cancellation fails the scope with `Cause.Interrupt`, and the
Scope monad has no cause-level catch operation.

## Current Recommendation

The best current direction is two-tiered:

- Effect.with_background for the common daemon-shaped no-handle case. This
  fixture passed and has been promoted as the first public candidate.
- Fiber_scope.with_fiber is viable for explicit await and explicit stop when it
  exposes `stop`, not raw `cancel`, as the cleanup-completing operation.

Do not expose raw daemon. Do not add a public API that returns a background
handle outside its owner.

## Verification

Commands run with `nix develop .#oxcaml -c ...`:

- `dune exec ./scratch/eta_research/scoped_sessions/p_scoped_5/background_no_handle.exe`
  - PASS, see results/background_no_handle.log.
- `dune exec ./scratch/eta_research/scoped_sessions/p_scoped_5/fiber_scope_with_handle.exe`
  - PASS, see results/fiber_scope_with_handle.log.
- `dune exec ./scratch/eta_research/scoped_sessions/p_scoped_5/external_app_comparison.exe`
  - PASS after adding `Supervisor.Scope.stop`, see results/external_app_comparison.log.
- `dune build ./scratch/eta_research/scoped_sessions/p_scoped_5/negative/fiber_scope_escape_negative.exe`
  - Expected compile failure, see results/fiber_scope_escape_negative.log.
