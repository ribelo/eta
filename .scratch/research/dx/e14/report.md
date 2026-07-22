# DX-E14 Report — `Eta.Promise`

Branch: `research/dx-e14-eta-promise`
Recommendation: **PROMOTE**

## V-DX-E14-001 — Decision

Status: **ACCEPT**.

Eta now exposes the one-pager's three-value backend-neutral one-shot cell:

```ocaml
type ('a, 'err) t
val create : unit -> ('a, 'err) t
val await : ('a, 'err) t -> ('a, 'err) Effect.t
val resolve : ('a, 'err) t -> ('a, 'err) Exit.t -> (bool, 'outer) Effect.t
```

One core implementation serves native Eio and js_of_ocaml CPS. It adds no
backend branch, contract field, fallback, polyfill, polling loop, timer, or
daemon. `Eio.Promise` remains the documented direct choice for Eio-only code.

## V-DX-E14-002 — Mechanism

Status: **ACCEPT**.

`Promise.t` holds synchronized unresolved waiters or the winning full `Exit.t`.
An unresolved `await` creates one promise/resolver pair from the active runtime
contract and registers the resolver with the cell. `resolve` commits under the
cell lock, snapshots all active waiters, and wakes each through the waiter's own
contract after releasing the lock. The public leaves use the audited internal
effect-erasure bridge, not `Effect.Expert.make`.

Cancellation and resolution follow first-commit ordering. Cancellation while
pending removes that waiter and propagates interruption. Settlement first makes
the stored exit authoritative even when the backend await surfaces cancellation
before its wake callback. On jsoo, E13's generic removable `Await` subscriptions
also unlink the CPS continuation synchronously. Scope close uses this ordinary
cancellation path; it does not close the cell.

## V-DX-E14-003 — Guarantee evidence

Status: **ACCEPT on both substrates**.

The programs and assertions live once in `test/core_common/promise_shared.ml`.
Native Alcotest and Node CPS use thin runners around that module.

| Guarantee | Shared executable case | Native Eio | Node CPS |
| --- | --- | --- | --- |
| First resolution wins; later returns false | `promise one-shot first exit preserved` | PASS | PASS |
| Three current awaiters all wake | `promise three waiters wake` | PASS | PASS |
| Cancelled waiter does not consume; live/later awaiters succeed | `promise cancelled waiter does not consume` | PASS | PASS |
| Boundary close interrupts pending await | `promise boundary close interrupts waiter` | PASS | PASS |
| Resolve after boundary close still succeeds | `promise boundary close interrupts waiter` | PASS | PASS |
| Resolution before cancellation preserves exit | `promise resolution before cancellation still delivers` | PASS | PASS |
| Typed failure and defect exits are delivered faithfully | `promise error and defect exit fidelity` | PASS | PASS |

The Node runner reached `eta_jsoo ok`; a lost wake cannot false-pass silently.
The cancellation-first case waits for cancellation cleanup before resolving; the
resolution-first case resolves and immediately cancels before scheduler resume.
These are deterministic portable orderings, not simultaneous thread stress.
Typed failure and defect cases park their backend waiters before resolution, so
fidelity is exercised through notification rather than only the settled fast
path.

## V-DX-E14-004 — Exact gates

Status: **ACCEPT**.

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo test/cache_jsoo test/signal_jsoo --force` | PASS |

Mainline repeated two existing integer-overflow warnings. All requested suites,
including unchanged cache and signal jsoo tracks, completed successfully.

## V-DX-E14-005 — Census and footguns

Status: **MATCHES SEALED PREDICTION**.

| Census | Before | Predicted | Actual | Delta |
| --- | ---: | ---: | ---: | ---: |
| Root `lib/eta/*.mli` files | 28 | 29 | 29 | **+1** |
| Concurrency/data cluster modules | 12 | 13 | 13 | **+1** |
| `Promise` public values | 0 | 3 | 3 | **+3** |
| New footguns | 0 | 0 | 0 | **+0** |

The MLI documents resolver authority, losing resolution, first-commit ordering,
and post-boundary-close usability without claiming cross-runtime/domain sharing.
The README moves the one-shot row to `Eta.Promise` and keeps the Eio-only fence
sentence. `docs/api-dx.md` distinguishes Promise, async, and Eio.Promise.

## V-DX-E14-006 — `Eta_test.Async`

Status: **HOLD, with evidence**.

No migration was made. `eta_test` intentionally depends on `eta_eio`, `eio`, and
`eio_main`; `Async` synchronously forks and awaits host test fibers outside an
Eta effect. Replacing its `Eio.Promise.t` with `Eta.Promise.t` would make await
effectful, require an active Eta runtime, and change the helper contract. The
jsoo track consumes the portable shared Promise suite directly without linking
`eta_test`. Native-only test files remain untouched.

## V-DX-E14-007 — Red-team and review

Status: **ACCEPT**.

`redteam/VERDICTS.md` records cancel-then-resolve, conflicting double resolve,
scope-abandoned waiter, and resolve-then-cancel attacks. All were refused with
shared test evidence and E13's jsoo retention regression.

The 14-line old review fixture exposes Expert context, scope, contract promise,
resolver, fork, park, and exit handling. The 16-line new fixture uses
`Eta.Promise` and checks duplicate resolution loudly. Both type-check against the
local interface.

| Criterion | Predicted | Independent final rating |
| --- | ---: | ---: |
| Application call-site improvement | 5/5 | **5/5** |
| Cancellation clarity from MLI | >=4/5 | **5/5** |
| Two-substrate confidence | >=4/5 | **5/5** |

Independent technical review found no state-machine correction necessary. It
sharpened cancellation-boundary wording, removed an untested cross-domain claim,
moved Exit fidelity through parked waiters, and distinguished functional
non-consumption evidence from source-reviewed top-level waiter removal. E13's
direct jsoo regression remains the executable proof that CPS subscriptions are
physically unlinked.

## V-DX-E14-008 — Prediction reconciliation

Status: **ACCEPT**.

The predicted synchronized shared wrapper, per-waiter runtime promises, ordinary
scope cancellation, resolve-after-close behavior, +1 module/+3 values/+0
footguns, review ratings, and `Eta_test.Async` hold all matched. The API review
improved the final packet by requiring explicit race ordering in the MLI, a loud
duplicate-producer check in `coord-new.ml`, and recorded focused outcomes.

Hypothesis ledger:

- **A. One public core wrapper over `Runtime_contract`: ACCEPTED.**
- **B. Separate native and jsoo modules: DOMINATED.**
- **C. Expert/naked Eio for portable application coordination: REJECTED.**
  Naked `Eio.Promise` remains accepted inside deliberate Eio-only code.

## V-DX-E14-009 — Final recommendation

**PROMOTE.** Both substrates execute one contract and one shared suite. The cell
has a clear one-shot commit, cancellation cannot consume settlement, all current
waiters wake, structured boundary close removes abandoned waiters, later awaits
remain valid, full exits are preserved, and all exact gates are green. No kill
condition fired.
