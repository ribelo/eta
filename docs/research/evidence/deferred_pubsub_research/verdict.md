# Deferred and Pubsub decision journal

## Decision question

Should Eta expose public Deferred and Pubsub modules, and if so what
implementation shape is supported by runnable evidence?

## Proof questions

| # | Proof question | Evidence | Status |
| --- | --- | --- | --- |
| P1 | Can Eta implement a typed one-shot Deferred over Eio promises? | Deferred_probe with multi-await, late failure replay, first completion wins | Proven |
| P2 | Can Pubsub be implemented from current Eta Queue/Channel primitives? | Pubsub_probe uses Queue for unbounded and Channel for bounded policies | Proven for tested policies |
| P3 | Does exposing raw Queue.t fail the lifecycle surface? | Negative fixture closes the raw queue inside an active subscription | Proven |
| P4 | Does explicit Drop_new produce observable drops without blocking? | Bounded capacity-1 fixture reports per-subscriber drops | Proven |
| P5 | Does Backpressure block and wake predictably? | Fixture blocks second publish until receive; fixture wakes blocked publisher on close; fixture cancels blocked publisher and proves later publish is not stuck behind it | Proven |
| P6 | Can scoped cleanup cover success, failure, and cancellation? | Escaped handle closes after body success, body failure, and body cancellation | Proven at runtime |
| P7 | Can the scoped API statically prevent escaped subscriptions? | Escaped handle can be stored, but is closed after scope exits | Not statically proven |
| P8 | Does naive per-subscriber Channel backpressure provide all-or-none publish? | Two-subscriber fixture cancels publish after it reaches subscriber A but while subscriber B is full | Contradicted |
| P9 | Does a shared hub buffer provide all-or-none publish under cancellation and normal backpressure release? | Shared_hub_probe repeats P8 and proves neither subscriber observes the canceled publish; another fixture proves publish waits until the lagging subscriber drains | Proven |

## Hypothesis ledger

| Candidate | Why plausible | Evidence that would win | Evidence that would falsify | Current status |
| --- | --- | --- | --- | --- |
| A. Document raw Queue set recipe | Smallest surface; matches current app pattern | Raw queues preserve lifecycle and close semantics without hidden invalid states | User can mutate/close subscriber queue while still active | Rejected |
| B. Pubsub.subscribe returns raw Queue.t | Simple API; close/error behavior delegated to existing Queue | Runtime fixtures pass and raw queue does not expose invalid lifecycle control | Negative fixture shows caller can close active subscription | Rejected |
| C. Abstract scoped subscription + explicit overflow, using per-subscriber Queue/Channel mailboxes | Pubsub owns fan-out lifecycle and policy while reusing Queue/Channel | Broadcast, drop, backpressure, close, escaped-handle fixtures pass | Backpressure can partially publish on cancellation/close | Partial: acceptable for mailbox-style Unbounded/Drop_new; rejected for atomic Backpressure |
| D. Shared hub buffer with subscriber cursors/refcounts | Usual bounded PubSub shape; one publication is admitted once and retained until subscribers consume or policy says otherwise | Atomic publish, scoped unsubscribe, close, drop/backpressure fixtures pass | Cursor/refcount state leaks entries or fails cancellation cleanup | Accepted and implemented |
| E. Full Effect-style PubSub with replay/sliding/publishAll | Powerful prior art | Sliding/replay fixtures prove implementation without extra primitive leakage | Current Eta Channel lacks drop-old/replay support and no call site needs it | Deferred |

## Cross-tab

| Criterion | Raw Queue recipe | Raw Queue subscribe | Per-subscriber Queue/Channel | Shared hub buffer |
| --- | --- | --- | --- | --- |
| Public surface size | Smallest | Small | Moderate | Moderate |
| Lifecycle ownership | Application-owned | Ambiguous | Pubsub-owned | Pubsub-owned |
| Invalid user mutation | Allowed | Allowed | Not exposed | Not exposed |
| Escaped handle behavior | Application-specific | Queue remains usable until closed | Runtime closes after scope | Runtime closes after scope |
| Slow subscriber policy | Hidden | Hidden unless documented elsewhere | Constructor-level | Constructor-level |
| Backpressure support | Caller-built | Not natural with Queue | Blocks, but partial publish on cancellation | Best hypothesis for atomic publish |
| Drop observability | Caller-built | Not natural with Queue | Per-subscriber drops | Hub-level drops; per-subscriber lag if sliding later |
| Evidence rung | Negative fixture only | Negative fixture | Runtime smoke plus negative P8 | Runtime smoke P9 plus production tests |

## Verdicts

### V-D1 - Add Deferred

Status: ACCEPT.

Decision: Implement a small Eta.Deferred as a typed one-shot around Eio promise
behavior.

Evidence: Deferred_probe proves multi-await, first completion wins, is_done, and
typed failure replay to late awaiters.

Remaining uncertainty: Whether Eta should also preserve full Cause.t/Exit.t.
That is not needed by current call sites and should be a later API if required.

Recommendation: ship create, await, complete, succeed, fail, is_done.

### V-P1 - Do not expose raw Queue.t subscriptions

Status: REJECT.

Decision: A subscribe surface that hands callers Queue.t is not the right public
Pubsub API.

Evidence: The negative fixture compiles and closes the subscriber queue inside
the active subscription body. That is exactly the lifecycle control Pubsub is
supposed to own.

Counterevidence considered: raw Queue.t is simpler and matches the Effect-pie
keyboard monitor shape. That pattern is fine inside applications, but it is not
enough for a library-owned fan-out protocol.

### V-P2 - Implement Pubsub with abstract scoped subscriptions

Status: ACCEPT for a first implementation slice.

Decision: Use an abstract subscription handle with recv, and a scoped subscribe
function that closes/removes subscriptions on body exit.

Evidence: Runtime fixtures prove escaped subscriptions fail closed after body
success, body failure, and body cancellation.

Remaining uncertainty: This is runtime enforcement, not static no-escape
enforcement. A rank-2 scope token could improve this later, but the current Eta
resource APIs also rely on scoped runtime cleanup.

### V-P3 - Make overflow policy explicit

Status: ACCEPT.

Decision: Require an overflow policy at construction. For v1, keep
Unbounded and Drop_new straightforward. Add Backpressure only if implemented
with hub-level atomic admission.

Evidence: Drop_new and Backpressure fixtures produce observably different
behavior using current Eta primitives. Drop_new reports dropped messages. A
single-subscriber Backpressure fixture blocks until receive, wakes on hub close,
and does not retain a canceled publisher waiter.

Counterevidence: A two-subscriber fixture shows the per-subscriber Channel
implementation can partially deliver a canceled publish to subscriber A while
subscriber B never receives it.

Recommendation: do not implement Backpressure as a loop over subscriber
Channels unless the API explicitly documents partial publish. Prefer a shared
hub buffer with cursors/refcounts.

### V-P4 - Use a shared hub buffer for Pubsub Backpressure

Status: ACCEPT.

Decision: Eta.Pubsub v1 uses a Pubsub-owned state machine:

- hub mutex protects global sequence numbers, close reason, subscriber table,
  retained entries, publisher waiters, and receiver waiters;
- publish is admitted once at the hub, not copied subscriber-by-subscriber;
- each subscription has a cursor into the shared sequence;
- each retained entry tracks remaining subscribers, or equivalent refcount;
- unsubscribe decrements remaining counts for entries the subscription has not
  consumed;
- when head entries reach zero remaining subscribers, remove them and wake
  blocked publishers;
- Backpressure waits at the hub when capacity is full, and cancellation removes
  the publisher waiter before admission;
- Drop_new returns without admitting the message when the hub is full;
- Unbounded uses the same cursor/refcount model without capacity pressure.

Evidence: Usual PubSub implementations use this family of designs because it
turns publish into a single hub-level state transition. The negative mailbox
fixture shows why mailbox composition is weaker for atomic Backpressure. The
Shared_hub_probe fixture then repeats the same cancellation scenario and proves
the canceled publish is visible to neither subscriber.

Implementation follow-up: lib/eta/pubsub.ml implements this shared-buffer
design, and test/eta/test_eta_pubsub.ml promotes the decisive runtime fixtures
into the production suite.

Remaining uncertainty: Sliding/drop-old and replay are plausible but untested.
They should stay out of v1 because Eta's current Channel does not expose a
drop-old operation and no current call site requires replay.

## Command

Run:

    nix develop -c dune exec .scratch/deferred_pubsub_research/runtime_smoke.exe

Latest result: pass, 18 scratch tests run. Production Eta suite also passes with
9 Pubsub tests. See run.out.
