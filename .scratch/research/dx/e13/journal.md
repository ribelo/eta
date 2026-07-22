# DX-E13 Journal — `Effect.async`

Branch: `research/dx-e13-effect-async`
Phase: D (runtime & model)

## Predictions (sealed)

Sealed before any E13 interface, implementation, test, documentation, red-team,
or review-packet edit. This file is the prediction record and will not be edited
after the predictions commit; wrong predictions remain as evidence.

### Decision and proof obligations

Decision: whether Eta can expose one callback-shaped core leaf with the same
one-shot, cancellation, defect, synchronous-resolution, and no-lost-wakeup
meaning on native Eio and js_of_ocaml CPS.

| # | Proof question | Minimum executable evidence | Risk | Predicted result |
| --- | --- | --- | --- | --- |
| E13-P1 | Can one callback resolve at most once across same-domain and cross-domain callers? | Double-resolution and seeded callback races | High | Proven by one atomic state transition |
| E13-P2 | Can interruption claim and run the optional canceler exactly once, protected from further interruption, without running it after resolution? | Cancellation, second-interrupt, and resolve/cancel race tests | High | Proven on both backends |
| E13-P3 | Does registration use ordinary exception capture? | Raising-register test with exact `Cause.Die` shape | Medium | Proven on both backends |
| E13-P4 | Can registration resolve synchronously without parking after a missed notification? | Resolve-inside-register test | High | Proven by latched promise settlement |
| E13-P5 | Is the resolution-versus-park and resolution-versus-cancel linearization point clean and testable? | Resume-before-park plus seeded cancel/register interleavings | High | Proven; no polling loop |
| E13-P6 | Does the same leaf map to js_of_ocaml CPS without a host polyfill or backend-specific semantic branch? | Shared guarantee suite compiled for Node CPS plus JS host-capability review example | High | Proven |

The promotion falsifier is any execution in which Eio and jsoo disagree about
which transition wins, when the canceler runs, or whether a pre-park resolution
is observable. Proof cost is not a falsifier. If the shared mechanism needs a
backend-specific fallback or a polling/default path, recommend **KILL**.

### Hypothesis space

| Candidate | Strongest case | Evidence needed to win | Falsifier | Predicted status |
| --- | --- | --- | --- | --- |
| A. One core `Custom` leaf over `Runtime_contract` promises | The contract already specifies one-shot queued wakeups and the only cross-domain wake operation | All guarantees pass unchanged on Eio and CPS | Any substrate needs different public semantics | **Accept** |
| B. Separate native and jsoo async interpreters | Each substrate could use its most direct scheduler API | Identical observable laws despite separate code | Semantic drift or extra backend API | **Dominated** by A if A passes |
| C. Keep application callbacks on `Expert.make` | No new core leaf or state machine | `Expert.make` call site is equally small and keeps lifecycle ownership clear | Review packet shows runtime machinery at the application boundary | **Reject** if A passes; baseline otherwise |

Candidate B remains plausible until the shared suite passes. Candidate C is the
boring baseline and wins if the six guarantees cannot be stated and proven on
both substrates.

### Predicted mechanism by guarantee and substrate

The leaf will create its runtime promise before invoking `register`. A private
atomic state has three logical states: pending, resolved, and interruption
claimed. The callback performs the sole pending-to-resolved compare-and-set,
then calls the contract's cross-domain-safe `resolve_promise`. Interruption
performs the sole pending-to-interruption-claimed compare-and-set. This is the
linearization point shared by both substrates.

Registration will run inside a dedicated `Runtime_contract.cancel_sub` and a
short cancellation-protected handoff. Its returned option is stored before a
deferred parent interruption can surface. The canceler is evaluated only by the
fiber that wins the interruption transition, under `Runtime_contract.protect`.
Canceler failure is predicted to use Eta's existing protected-cleanup
finalizer/suppressed-finalizer diagnostic path rather than being discarded.

| Guarantee | Native Eio prediction | js_of_ocaml CPS prediction |
| --- | --- | --- |
| 1. One-shot resolution | `Atomic.compare_and_set` selects the first callback; `Eio.Promise.resolve` queues its exit; later callbacks return without resolving | The same state transition selects the first callback; the CPS promise settles once and schedules its continuation; later callbacks are dropped |
| 2. Canceler | Parent cancellation reaches the async sub-context; pending-to-interruption claims the optional canceler once; `Eio.Cancel.protect` lets it finish. Resolved state wins over later interruption and suppresses the canceler | The CPS cancel waiter reaches the same transition; protection depth prevents first or second cancellation from discontinuing the canceler. Resolved state likewise prevents cleanup |
| 3. Register raises | Non-cancellation exceptions leave through `exit_of_exn`, producing ordinary `Cause.Die`; runtime cancellation remains interruption | Identical core capture; a JS exception raised by registration becomes `Cause.Die`, while `Eta_jsoo.Cancelled` remains interruption |
| 4. Synchronous resolution | Promise exists before registration, so an inline callback settles it before `await_promise`; `Eio.Promise.await` observes the settled value | CPS promise state becomes `Settled` before subscription; later subscription schedules the stored result rather than losing it |
| 5. No lost wakeup | Promise settlement is the queued resume, and the atomic state decides resolution versus cancellation before parking; a resolved-but-not-yet-woken fiber re-awaits under protection | `subscribe` handles both `Pending` and `Settled`; microtask scheduling is the queued resume, with the same atomic race decision and no timer/poll fallback |
| 6. jsoo/T10 | No native-only type or operation enters the leaf | The same core leaf uses `create_promise` / `resolve_promise` / `await_promise`; JS wrappers must test required host APIs and fail loudly, never install a polyfill |

### Predicted guarantee tests

I predict a shared callback-style core suite can own the programs and assertions,
with thin Eio and jsoo runners supplying only runtime execution and host
scheduling. The same named cases will run on both backends:

1. `async one-shot first resolution wins`
2. `async canceler runs once on interruption`
3. `async canceler is uninterruptible under second interrupt`
4. `async canceler never runs after resolution`
5. `async register raise becomes die`
6. `async synchronous resolution does not deadlock`
7. `async no lost wakeup under seeded register/cancel races`

The no-lost-wakeup test will force resume-before-park directly and exercise a
fixed seed corpus of registration/cancellation orderings. JavaScript is
single-threaded, so its seeds predict microtask order rather than simultaneous
machine execution; the report must not call that cross-domain stress. Native
will additionally exercise callbacks from another domain if the shared runner
can do so without widening production APIs.

### Predicted census, footguns, and review outcome

The explicit pre-composition construction/lifting cluster in `effect.mli`
currently has **12** values (`pure`, `fail`, `unit`, `from_result`,
`from_option`, `flatten_result`, `sync`, `sync_result`, `sync_option`, `yield`,
`never`, `die_message`). Prediction: **12 -> 13, delta +1**. Callback-shaped
constructors are **0 -> 1**. `Effect.Expert` has **13** values and remains
**13 -> 13, delta 0**.

Predicted new-footgun delta: **+0**. The two required documented edges are that
only the first callback exit is accepted and that a canceler must not block
indefinitely because interruption waits for its protected completion. Late
callbacks are harmless dropped calls. This replaces an application-level
`Expert.make` escape hatch rather than adding a second low-level choice.

Using 1 = reject and 5 = approve, predicted independent ratings are:

- API/call-site improvement: **5/5** for `async` versus **2/5** for
  application-owned `Expert.make`.
- cancellation contract clarity: **4/5 or better** if the MLI remains within
  roughly 15 lines and the three canceler teach-back questions are answered
  without reading implementation code.
- two-substrate confidence: **4/5 or better** only if every named guarantee case
  runs from the shared suite on both Eio and Node CPS.

Likeliest reviewer misreadings: that a second callback raises rather than being
dropped; that the canceler runs after normal resolution; or that protection can
make an indefinitely blocking canceler safe. The MLI, review questions, and
red-team artifacts must make all three answers explicit.

### Promote / hold / kill prior

Predict **PROMOTE** only when the full native and mainline gates pass and all
seven named cases prove the six guarantees on both substrates. Predict **HOLD**
with the divergence recorded if implementation works on only one substrate.
Predict **KILL** if either backend cannot cleanly test the resume-before-park
guarantee or needs a fallback, polyfill, polling loop, or weakened canceler law.
