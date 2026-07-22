# DX-E13 Report — `Effect.async`

Branch: `research/dx-e13-effect-async`
Recommendation: **PROMOTE**

## V-DX-E13-001 — Decision

Status: **ACCEPT**.

Eta now exposes the callback-shaped leaf fixed by the one-pager:

```ocaml
val async :
  register:((('a, 'err) Exit.t -> unit) -> (unit, 'err) t option) ->
  ('a, 'err) t
```

One core implementation serves native Eio and js_of_ocaml CPS through
`Runtime_contract`; no backend contract, backend-specific async interpreter,
fallback, polling loop, or polyfill was added. `Expert.make` remains the
runtime-package extension point and no call site was migrated.

## V-DX-E13-002 — Mechanism

Status: **ACCEPT**.

`Effect.async` is a named `Custom` leaf with a concurrency footprint.

1. It creates the runtime one-shot promise before calling `register`.
2. A private atomic state is one of `Pending`, `Resolved exit`,
   `Interrupt_claimed`, or `Closed`.
3. The first callback performs `Pending -> Resolved exit`, publishing the full
   winning `Exit.t` before calling the cross-domain-safe `resolve_promise`.
   Every later callback fails that transition and returns without touching the
   resolver.
4. Registration runs in a dedicated `cancel_sub` and a short protected handoff.
   The returned optional canceler is stored before deferred cancellation can
   surface.
5. Interruption performs `Pending -> Interrupt_claimed`. Only that winner runs
   the published canceler, under `Runtime_contract.protect`. If resolution
   already won, interruption returns the atomically published exit and never
   runs the canceler.
6. A successful canceler preserves the original interruption. Typed failure or
   defect becomes a rendered finalizer diagnostic suppressed under that
   interruption. Registration defects close pending state and use ordinary
   `exit_of_exn` capture as `Cause.Die`; late callbacks are dropped.

The atomic payload is authoritative for the resolution/cancellation race. It is
not safe to re-await under protection after observing a resolution, because
both backends surface pending cancellation when leaving protected execution.

Native uses the existing Eio promise, cancellation sub-context, and
`Eio.Cancel.protect` implementation. The callback closure calls only `Atomic`
and the contract's explicitly cross-domain `resolve_promise`; 32 native trials
race two callback domains and accept exactly one result.

jsoo uses the same core state machine. Its promise changes to `Settled` before
scheduling subscribers, and a subscriber arriving after settlement schedules
the stored result. CPS protection depth prevents cancellation from discontinuing
the canceler. Promise subscriptions are removable: cancellation synchronously
unsubscribes the CPS continuation from a still-pending promise before scheduling
discontinuation. This applies to every jsoo `Await`, not only `Effect.async`.
The Node runner has a `beforeExit` completion sentinel, so a lost wakeup cannot
false-pass because no host handles remain.

## V-DX-E13-003 — Guarantee evidence

Status: **ACCEPT on both substrates**.

The programs and assertions below live once in
`test/core_common/effect_async_shared.ml`. Native Alcotest and Node CPS use thin
runners around that same module.

| Guarantee | Shared executable cases | Native Eio | Node CPS |
| --- | --- | --- | --- |
| 1. First `Exit.t` wins; later calls drop | `async one-shot first resolution wins` | PASS, plus `async cross-domain callback-vs-callback settles once` (32 trials) | PASS |
| 2. Canceler: interruption only, at most once, protected, never after resolution | `async canceler runs once on interruption`; `async canceler survives pending interruption across yields`; `async canceler never runs after resolution`; typed-failure and defect suppression cases | PASS | PASS |
| 3. Register raise becomes `Cause.Die` | `async register raise becomes die`; `async register raise wins after synchronous resume` | PASS | PASS |
| 4. Synchronous resolution does not deadlock | `async synchronous resolution does not deadlock` | PASS | PASS; completion sentinel reached |
| 5. No registration/parking wakeup loss | synchronous case plus `async fixed same-domain resolution/cancel orderings preserve wakeups` | PASS, plus cross-domain callback-vs-callback trials | PASS; completion sentinel reached |
| 6. Same jsoo CPS meaning; no host polyfill | the entire shared suite, linked unchanged into `test_eta_jsoo`; review examples require both EventTarget methods | PASS as shared core source | PASS under `--effects=cps` |

The canceler diagnostic cases are:

- `async canceler failure is suppressed under interruption`;
- `async canceler defect is suppressed under interruption`.

The twelve fixed cases are deterministic same-domain scheduler-visible
orderings selected from
synchronous resolution, resolution-before-interruption, and
interruption-claim-before-late-resolution. They are not simultaneous thread
stress. Full post-return/pre-await seeding is impossible on single-thread jsoo:
there is no host scheduler turn between ordinary `register` return and the CPS
await handler installing its subscriber. The forceable proof is settlement
before any subscriber exists; fixed orders cover both race winners once the
scheduler can run another task. Native adds real cross-domain
callback-vs-callback competition. It does not add cross-domain cancellation:
the erased runtime contract permits only `resolve_promise`, not `cancel`, away
from the owner domain.

## V-DX-E13-004 — Exact gates

Status: **ACCEPT**. After the final retention and throwing-hook corrections,
every required follow-up gate was rerun from the final worktree and passed. All
mainline commands used the isolated `_build-mainline` directory.

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo test/cache_jsoo test/signal_jsoo --force` | PASS, including unchanged signal suite |

The mainline compiler repeated the repository's existing integer-overflow
warnings for two large constants; tests completed successfully. Focused
construction runs also passed `test/core_eio` with 554 cases and `test/js_jsoo`
with all ten shared async cases reaching the terminal sentinel.

## V-DX-E13-005 — Census and footguns

Status: **MATCHES SEALED PREDICTION**.

The pre-experiment interface is commit `9c04048e`; the post-experiment interface
is this branch.

| Census | Before | Predicted | Actual | Delta |
| --- | ---: | ---: | ---: | ---: |
| Pre-composition construction/lifting cluster | 12 | 13 | 13 | **+1** |
| Callback-shaped public constructors | 0 | 1 | 1 | **+1** |
| Top-level `Effect` values (excluding nested `Expert`) | 123 | 124 | 124 | **+1** |
| `Effect.Expert` value declarations | 13 | 13 | 13 | **0** |
| New footguns | 0 | 0 | 0 | **+0** |

The construction cluster is the sealed explicit list from `pure` through
`die_message`, now plus `async`. A production `Effect.Expert.make` scan found
only runtime-package shapes under stream, cache, signal, JS stream, HTTP client,
and pool internals. No application-level migration candidate was found.

The two required edges are documented, not counted as new footguns:

- only the first call to `resume` is accepted; later calls are dropped;
- interruption waits for the uninterruptible canceler, so a canceler must
  terminate.

Registration is also required to return promptly. Host capability absence must
fail loudly in the wrapper; Eta does not install a fallback or polyfill.

## V-DX-E13-006 — Red-team

Status: **ACCEPT**.

Detailed verdicts are in `redteam/VERDICTS.md`.

| Attack | Outcome |
| --- | --- |
| Call `resume` three times with conflicting exits | First exit retained; all later calls visibly attempted and dropped before resolver access |
| Resolve before any park/subscriber and race registration with cancellation | Promise latch and atomic winner refuse the lost-wakeup construction on both backends |
| Return `Some Effect.never` as canceler | Trap confirmed: interruption waits forever by contract; no hidden timeout or detach is safe |
| Retain `resume` after jsoo cancellation | Canceled `Await` unsubscribes; the pending promise observably retains zero subscriptions |

The blocking-canceler attack is documented rather than executed indefinitely.
The bounded pending-interruption test proves that Eta waits for protected cleanup
across yields and continues only when that cleanup is released.

## V-DX-E13-007 — Review and prediction reconciliation

Status: **ACCEPT with one useful prediction miss**.

Independent final ratings:

| Criterion | Predicted | Actual |
| --- | ---: | ---: |
| Application call-site improvement | 5/5 | **5/5** |
| Cancellation contract clarity | >=4/5 | **5/5** |
| Two-substrate confidence | >=4/5 | **5/5** application review; **4/5** technical confidence |

The final technical verdict is **PROMOTE**. The review packet is under
`review/`; both examples are 26 lines, check `addEventListener` and
`removeEventListener` loudly, and install no polyfill. Teach-back answers follow
from the MLI without reading implementation.

Prediction miss: the sealed journal predicted that cancellation observing
resolved state would re-await the promise under protection. Independent review
showed that this is wrong because protection re-surfaces pending cancellation on
exit. The implementation instead stores `Resolved exit` atomically and returns
that payload directly. The sealed journal was not edited.

Additional evidence beyond prediction: ten shared cases rather than seven, two
explicit canceler-failure shapes, registration-defect precedence after a
synchronous callback, the Node completion sentinel, and native cross-domain
callback-vs-callback competition.

Hypothesis ledger result:

- **A. One core leaf over `Runtime_contract`: ACCEPTED.**
- **B. Separate native and jsoo interpreters: DOMINATED.** No separate code was
  needed to obtain the same laws.
- **C. Keep application callbacks on `Expert.make`: REJECTED.** The review packet
  shows the runtime context, promise, settlement guard, parking, cancellation
  inspection, and cleanup code removed from the application wrapper.

## V-DX-E13-008 — Final recommendation

**PROMOTE.** Both substrates implement and execute one contract. The first
callback and interruption share a clean atomic linearization point; synchronous
settlement is latched; cancellation cleanup is one-shot and protected; defects
and cleanup diagnostics follow Eta's existing cause model; jsoo uses the same
CPS promise discipline; all exact gates and the unchanged signal jsoo suite are
green. No hold or kill condition fired.

## V-DX-E13-009 — Correctness follow-up 1

Status: **RESERVATIONS FIXED**.

The independent correctness review found no async state-machine race,
cancellation duplication, or lost wakeup. Its `CORRECT-WITH-RESERVATIONS`
verdict identified one jsoo retention defect and two evidence-honesty defects.

1. **Retention:** before the fix, cancellation marked `resumed` but left the CPS
   callback in an unresolved promise's pending list. A host-retained `resume`
   could therefore root the canceled continuation indefinitely. `subscribe` now
   returns an idempotent unsubscriber, and the `Await` cancellation path removes
   the subscription before scheduling discontinuation. The regression first
   failed with one retained callback and now passes with
   `Private.pending_subscriptions promise = 0`. A direct non-async
   `Private.await` is the executable witness; the same `Await` handler backs
   runtime-contract promises and `Effect.never`. A second regression proves a
   throwing cancellation hook is resumed as a defect after unsubscription and
   cannot strand the waiter or scope shutdown.
2. **MLI honesty:** the contract now says registration itself is
   cancellation-protected until return and must return promptly.
3. **Evidence honesty:** the protected-canceler case names the already-pending
   interruption across yields; fixed same-domain orderings are not called race
   stress; the native trial is named callback-vs-callback. A callback-vs-cancel
   cross-domain trial is intentionally absent because `Runtime_contract.cancel`
   is owner-domain-only.

The `Effect.async` signature and six guarantees are unchanged. Attack D and its
before/after evidence are recorded in `redteam/VERDICTS.md`.
