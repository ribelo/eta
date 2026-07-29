# Follow-up 1: DX-E41 — kill the `?random:None` wart before merge

Everything else verified clean: gates, scope-exit matrix, preservation
suite, census (exact hits), law registry R167–R175, red-team, hold-trigger
audit. One issue remains, in a signature that is not yet on master — we fix
it now, not after release.

## The problem

`with_auto`'s parameter order is `?on_error -> load: -> ?random ->
schedule: -> body`. At `let@` sites (and any site where `body` is not
syntactically applied), OCaml cannot erase `?random`, so users must write
`?random:None` explicitly. Evidence in your own diff:
`examples/cached_resource.ml:33`, `test/api_dx/api_dx_examples.ml:1233,
1243, 1252`. A brand-new public signature that forces `?random:None` on
its canonical usage form is a DX defect. (Note that `?on_error` — placed
before `load:` — erases fine at the same sites; the mechanism is already
proven by your diff.)

No call site anywhere passes `?random:Some`. Zero usage of the capability
through this parameter.

## Two acceptable endpoints — choose by evidence, document the choice

**Endpoint A (preferred if the evidence supports it): delete `?random`.**
E19 gave the runtime a scoped-random override (`Effect.with_random`,
resolution mechanism at `lib/eta/runtime_core.ml:196-197`). If the refresh
loop's `Schedule.start` can honor the scoped random binding without an
explicit parameter — the same way `Effect.retry`'s driver resolution works
at interpretation time — then `?random` is redundant vocabulary (T1: one
way to inject randomness, and it's the fiber-local one). Investigate:
(a) how `Effect.retry` resolves random at `Schedule.start`;
(b) whether that resolution path is reachable from `eta_cache`'s altitude
without new core surface. If yes: delete the parameter, route the loop
through the scoped resolution, and document `with_random` as the
deterministic-injection path in `refreshable.mli` (one sentence, with a
doc example only if it stays inside the budget). If it requires new core
surface, stop — that's Endpoint B, plus a one-paragraph journal note
naming the missing leaf (feeds the E43 evidence pool).

**Endpoint B (guaranteed): reorder `?random` before `load:`.**
`?on_error -> ?random -> load: -> schedule: -> body`. Your diff already
proves the mechanism (everything before `load:` erases at `let@` sites).
No semantic change; no new concepts.

## Required either way

1. Remove every forced `?random:None` from call sites (example + api_dx
   fixtures).
2. **Erasure regression test** (the E24 lesson): compile/run evidence that
   `let@ h = Refreshable.with_auto ~load ~schedule in body` works with no
   optional argument mentioned, and that the direct-call form
   `with_auto ~load ~schedule (fun h -> ...)` is unchanged. Promote it into
   the parity suites.
3. If you choose A: a determinism test — `with_random` wrapping
   `with_auto` makes the jittered schedule's draw sequence reproducible;
   without it, show the loop still uses the runtime default.
4. Journal entry (new section, sealed predictions untouched): which
   endpoint, the evidence for it, and — if A fails on a missing leaf —
   the named leaf for E43.
5. Report: append a `Follow-up 1 outcome` section (do not rewrite the
   original report body).

## Gates

Same four. If only signatures/call sites move, the full quartet is still
required (they're cheap; certainty is the point).

## Done means

`E41 READY FOR REVIEW` again (or `E41 BLOCKED: <reason>`). Same scope
fence as objective.md. This file stays uncommitted.
