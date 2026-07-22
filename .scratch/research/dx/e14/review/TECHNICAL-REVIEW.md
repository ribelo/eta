# DX-E14 Independent Technical Review

Final verdict: **CORRECT after evidence/doc corrections**.

The independent reviewer found the production state machine fundamentally
correct: one lock linearizes waiter registration, cancellation removal, and
settlement; notification occurs outside the lock; every waiter is resolved
through its own contract; and stored resolution is authoritative if backend
cancellation arrives before wake delivery. No implementation change was
recommended.

Corrections made from review:

1. `promise.mli` now names an owning cancellation boundary rather than claiming
   every ordinary scope return cancels finite children, and spells out both
   cancellation/resolution orders.
2. The MLI no longer claims cross-runtime/domain sharing. That stronger property
   was not required by the one-pager and was not exercised by the shared suite.
3. Typed-failure and defect fidelity now pass through already-parked backend
   waiters, not only the late `Settled` fast path.
4. The resolution-first test name now describes its deterministic ordering
   instead of calling it simultaneous race stress.
5. Removal evidence is stated honestly: functional shared tests prove that
   cancellation cannot consume the cell; source review proves the top-level
   waiter is filtered; E13's direct jsoo regression proves the underlying CPS
   subscription count reaches zero. No public inspection API was added solely
   for tests.

The reviewer independently ran an isolated OxCaml install build, the six native
Promise cases, the mainline jsoo suite with its completion sentinel, and
`git diff --check`; all passed before these final evidence refinements. The exact
assignment gates were rerun afterward on the final worktree.
