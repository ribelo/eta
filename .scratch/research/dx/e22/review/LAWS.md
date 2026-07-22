# E22 law census

This census distinguishes laws normatively stated in public interfaces from
model laws selected by E22 but not yet stated in prose. A row is one behavioral
or algebraic claim. Several rows may cite one matrix property when that property
directly discriminates every cited claim.

Current census: **73 mli-stated claims**, **2 prose-pending model claims**, and
**53 unique named qcheck properties** in `test/laws/law_properties.ml`.

## Mli-stated laws

| ID | Claim | Exact normative span | Named qcheck property |
| --- | --- | --- | --- |
| M01 | `map` identity holds for total pure functions. | `lib/eta/effect.mli:152-155` | `map identity` |
| M02 | `map` composition holds for total pure functions. | `lib/eta/effect.mli:152-155` | `map composition` |
| M03 | `pure`/`bind` left identity holds for total continuations. | `lib/eta/effect.mli:165-168` | `pure/bind left identity` |
| M04 | `pure`/`bind` right identity holds for total continuations. | `lib/eta/effect.mli:165-168` | `pure/bind right identity` |
| M05 | `bind` is associative for total continuations. | `lib/eta/effect.mli:165-168` | `bind associativity` |
| M06 | `bind_error handler (fail error)` is `handler error`. | `lib/eta/effect.mli:256-257` | `bind_error left identity` |
| M07a | `bind_error` makes one recovery decision rather than handling every typed leaf. | `lib/eta/effect.mli:247-254` | `bind_error handles exactly once with the first typed failure in cause order` |
| M07b | `bind_error` chooses the first typed failure in cause order. | `lib/eta/effect.mli:251-254` | `bind_error handles exactly once with the first typed failure in cause order` |
| M07c | `bind_error` does not handle causes containing defects, interruption, or finalizer diagnostics. | `lib/eta/effect.mli:247-254` | `bind_error never handles defect interruption or finalizer diagnostics` |
| M08 | `fold` is coherent with success `map` and typed-error `bind_error`. | `lib/eta/effect.mli:273-282` | `fold coherence with map/bind_error` |
| M09 | `race` returns the first value and cancels the losers. | `lib/eta/effect.mli:185-188` | `race loser cancellation releases an actually held scoped resource` |
| M10 | A cancelled race loser releases an actually held scoped resource. | `lib/eta/effect.mli:188-191` | `race loser cancellation releases an actually held scoped resource` |
| M11 | Successful `par left right` returns its pair in input position order, independent of completion order. | `lib/eta/effect.mli:202-205` | `par preserves pair input order across both observable completion directions` |
| M12 | `par` propagates the first child failure and cancels its sibling. | `lib/eta/effect.mli:203-205` | `par fail-fast cancels pending sibling and waits for observable finalizer` |
| M13 | `all` returns successful values in input order. | `lib/eta/effect.mli:211-214` | `all collects results in input order after reverse observable completion` |
| M14 | `all` cancels remaining children after the first observed failure. | `lib/eta/effect.mli:212-214` | `all first observed failure cancels siblings and awaits their finalizers` |
| M15 | `all` propagates the cause of the first observed failure. | `lib/eta/effect.mli:212-214` | `all first observed failure cancels siblings and awaits their finalizers` |
| M16 | `all_settled` captures every child failure as an `Error cause` value. | `lib/eta/effect.mli:216-220` | `all_settled captures every child cause and preserves input order` |
| M17 | `all_settled` returns child outcomes in input order. | `lib/eta/effect.mli:216-220` | `all_settled captures every child cause and preserves input order` |
| M18 | `map_par` returns mapped values in input order despite completion order. | `lib/eta/effect.mli:222-228` | `map_par preserves input order across both observable completion directions` |
| M19 | `map_par` cancels in-flight siblings after the first failure. | `lib/eta/effect.mli:227-228` | `map_par first failure cancels in-flight siblings and awaits scoped release` |
| M20 | `map_par ~max_concurrent` never exceeds its configured child-fiber bound. | `lib/eta/effect.mli:230-232` | `map_par never exceeds max_concurrent and reaches the bound when inputs suffice` |
| M21 | `finally` runs cleanup after success, typed failure, defect, and cancellation. | `lib/eta/effect.mli:511-515` | `finally exactly once across success/typed-failure/defect/cancellation exit kinds` |
| M22 | Cleanup failure after body success is reported as `Cause.Finalizer`. | `lib/eta/effect.mli:515-517` | `finally cleanup failure after success is a finalizer cause` |
| M23 | Cleanup failure after body failure is suppressed under the primary cause. | `lib/eta/effect.mli:517-519` | `finally cleanup failure is suppressed under a primary failure` |
| M24 | The lexical resource bracket releases when its body finishes with protected cleanup semantics. | `lib/eta/effect.mli:574-585,600-616` | `with_resource release across success/typed-failure/defect/cancellation exit kinds` |
| M24a | Bracket release failure after body success becomes `Cause.Finalizer`. | `lib/eta/effect.mli:579-585` | `with_resource release failure after body success becomes Cause.Finalizer` |
| M24b | Bracket release failure after body failure is suppressed under the primary cause. | `lib/eta/effect.mli:579-585` | `acquire_use_release release failure is suppressed under body failure` |
| M25 | `with_scope` releases resources in reverse acquisition order. | `lib/eta/effect.mli:625-630` | `scope reverse acquisition/release order` |
| M26 | `with_scope` finalizers run on success, typed failure, defect, and cancellation. | `lib/eta/effect.mli:628-630` | `with_scope releases registered resources on success typed failure defect and cancellation` |
| M27 | Nested scopes finish inner releases before the outer scope continues and releases. | `lib/eta/effect.mli:632-633` | `nested with_scope releases inner resources before outer continuation and finalizer` |
| M28 | A clock override restores after every exit kind. | `lib/eta/effect.mli:711-715` | `dynamic override restoration across each exit kind` |
| M29 | The innermost clock override wins and restores the exact outer clock. | `lib/eta/effect.mli:711-715` | `nested clock override uses innermost binding and restores each exact outer clock` |
| M30 | Clock overrides are isolated between `par` siblings. | `lib/eta/effect.mli:711-715` | `override sibling isolation under par` |
| M31 | A random-source override restores after every exit kind. | `lib/eta/effect.mli:722-726` | `dynamic override restoration across each exit kind` |
| M32 | The innermost random-source override wins and restores the exact outer source. | `lib/eta/effect.mli:722-727` | `nested random logger and tracer overrides use innermost bindings and restore exact outer observations` |
| M33 | Random-source overrides are isolated between `par` siblings. | `lib/eta/effect.mli:723-727` | `override sibling isolation under par` |
| M34 | A logger override restores after every exit kind. | `lib/eta/effect.mli:732-736` | `dynamic override restoration across each exit kind` |
| M35 | The innermost logger override wins and restores the exact outer sink. | `lib/eta/effect.mli:732-737` | `nested random logger and tracer overrides use innermost bindings and restore exact outer observations` |
| M36 | Logger overrides are isolated between `par` siblings. | `lib/eta/effect.mli:733-736` | `override sibling isolation under par` |
| M37 | A tracer override restores after every exit kind. | `lib/eta/effect.mli:741-745` | `dynamic override restoration across each exit kind` |
| M38 | The innermost tracer override wins and restores the exact outer tracer. | `lib/eta/effect.mli:741-748` | `nested random logger and tracer overrides use innermost bindings and restore exact outer observations` |
| M39 | Tracer overrides are isolated between `par` siblings. | `lib/eta/effect.mli:742-745` | `override sibling isolation under par` |
| M40 | Nested scoped log attributes accumulate outer-to-inner before per-call attributes. | `lib/eta/effect.mli:931-938` | `log pipeline applies stricter nested minimum then outer inner and call attrs before transform and sink` |
| M41 | Nested minimum log levels use the stricter effective threshold. | `lib/eta/effect.mli:940-949` | `log pipeline applies stricter nested minimum then outer inner and call attrs before transform and sink` |
| M42 | Log processing order is minimum filter, attributes, interceptors, then sink. | `lib/eta/effect.mli:957-966` | `log pipeline applies stricter nested minimum then outer inner and call attrs before transform and sink` |
| M43 | Nested log interceptors run outermost first and pass replacements inward. | `lib/eta/effect.mli:961-964` | `nested log interceptors run outermost first and pass replacements inward` |
| M44 | `Drop` stops the log pipeline before later interceptors and the sink. | `lib/eta/effect.mli:951-955,961-964` | `outer log interceptor Drop skips inner interceptors and the sink` |
| M45 | Channel close wakes blocked senders and receivers. | `lib/eta/channel.mli:8-11,62-69` | `Channel graceful close fence/drain/reason ordering` |
| M46 | Buffered Channel values remain drainable before receivers observe the close reason. | `lib/eta/channel.mli:8-11,50-54` | `Channel graceful close fence/drain/reason ordering` |
| M47 | Buffered Channel values are received FIFO. | `lib/eta/channel.mli:13-15` | `Channel graceful close fence/drain/reason ordering` |
| M48 | Active blocked Channel senders are admitted FIFO as capacity opens. | `lib/eta/channel.mli:13-15` | `Channel admits active blocked senders FIFO as capacity opens` |
| M49 | A Channel send fenced by close fails with the winning close reason. | `lib/eta/channel.mli:40-48` | `Channel graceful close fence/drain/reason ordering` |
| M50 | Cancelling a blocked Channel sender removes its slot and increments `cancelled_senders`. | `lib/eta/channel.mli:44-48` | `Channel blocked-sender cancellation removes waiter increments counter and consumes no value` |
| M51 | Channel close is idempotent and the first close reason wins. | `lib/eta/channel.mli:62-69` | `Channel graceful close fence/drain/reason ordering` |
| M52 | Graceful Queue close rejects future producer operations. | `lib/eta/queue.mli:6-8` | `Queue graceful close/error ordering` |
| M53 | Graceful Queue close drains buffered values before exposing its reason. | `lib/eta/queue.mli:6-8` | `Queue graceful close/error ordering` |
| M54 | Queue close is idempotent and the first close reason wins. | `lib/eta/queue.mli:167-172` | `Queue graceful close/error ordering` |
| M54a | Queue shutdown is idempotent and preserves its committed state, counters, and `Closed` reason. | `lib/eta/queue.mli:181-182` | `Queue repeated shutdown preserves committed state counters and Closed reasons` |
| M55 | Queue shutdown wakes blocked producers, consumers, and `await_shutdown` waiters. | `lib/eta/queue.mli:9-11,181-188` | `Queue shutdown wakes blocked producer consumer and await_shutdown waiter` |
| M56 | Queue shutdown immediately drops buffered values. | `lib/eta/queue.mli:9-11` | `Queue shutdown immediately drops buffered values and closes future operations` |
| M57 | Future Queue producer and consumer operations report `Closed` after shutdown. | `lib/eta/queue.mli:9-11` | `Queue shutdown immediately drops buffered values and closes future operations` |
| M58 | Cancelling a blocked Semaphore acquire removes its waiter without consuming permits. | `lib/eta/semaphore.mli:22-28` | `Semaphore waiting-cancellation safety/no permit consumption` |
| M59 | Semaphore waiters are awakened in FIFO order when their requests can be satisfied. | `lib/eta/semaphore.mli:1-8,30-32` | `Semaphore wakes blocked permit waiters in FIFO order` |
| M60 | `with_permits` releases held permits after success, typed failure, and cancellation. | `lib/eta/semaphore.mli:37-40` | `Semaphore.with_permits releases on success typed failure defect and cancellation` |
| M61 | `with_permits_or_abort` returns `Some` after acquisition/body and `None` when abort wins without running the body. | `lib/eta/semaphore.mli:42-51` | `Semaphore.with_permits_or_abort returns Some for acquisition and None for abort` |
| M62 | `with_permits_or_abort` releases permits on success, typed failure, defect, abort, cancellation, and outer result discard. | `lib/eta/semaphore.mli:53-55` | `Semaphore.with_permits_or_abort releases on success failure defect abort and cancellation` |
| M63 | Terminal `Done` schedule metadata has exactly zero delay. | `lib/eta/schedule.mli:22-24` | `Schedule terminal Done metadata delay is exactly Duration.zero` |
| M64 | `and_then` tags first-phase outputs before second-phase outputs. | `lib/eta/schedule.mli:30-34` | `Schedule.and_then tags every first phase output before every second phase output` |
| M65 | `tap_input` runs its hook before each inner schedule step. | `lib/eta/schedule.mli:68-74` | `Schedule.tap_input precedes each step and abandoned Hook retry preserves driver state` |
| M66 | A failed or abandoned `tap_input` hook does not advance inner schedule state. | `lib/eta/schedule.mli:72-74` | `Schedule.tap_input precedes each step and abandoned Hook retry preserves driver state` |
| M67 | `tap_output` runs after every produced output, including terminal `Done`. | `lib/eta/schedule.mli:76-82` | `Schedule.tap_output runs after every produced output including terminal Done` |
| M68 | `next` returns `Some metadata` exactly for `Continue` and `None` for terminal `Done`. | `lib/eta/schedule.mli:133-140` | `Schedule.next returns Some exactly for Continue and None exactly for terminal Done` |

## Model laws (prose pending)

These E22 bootstrap laws are executable but are not presented as mli-stated
claims. Promotion into `schedule.mli` needs a separately reviewed statement of
valid constructor domains; until then their provenance is explicit.

| ID | Model claim | Declaration location | Named qcheck property | Prose status |
| --- | --- | --- | --- | --- |
| P01 | Valid exponential, fibonacci, and nonnegative linear schedules produce exactly the requested prefix of nondecreasing delays. | `lib/eta/schedule.mli:36-43` | `monotone delay sequences for valid exponential/fibonacci/linear schedules` | PENDING (`FG-E22-001`) |
| P02 | `recurs n` emits exactly `n` `Continue` steps before `Done`. | `lib/eta/schedule.mli:22-28,36,125-140` | `recurs n step count` | PENDING (`FG-E22-001`) |

## Census totals

| Mli | Mli-stated claims | Model claims | Distinct properties touching this mli |
| --- | ---: | ---: | ---: |
| `lib/eta/effect.mli` | 48 | 0 | 34 |
| `lib/eta/schedule.mli` | 6 | 2 | 7 |
| `lib/eta/channel.mli` | 7 | 0 | 3 |
| `lib/eta/queue.mli` | 7 | 0 | 4 |
| `lib/eta/semaphore.mli` | 5 | 0 | 5 |
| **Total** | **73** | **2** | **53 properties** |

The executable contains 53 unique properties in total. Matrix properties cover
multiple one-claim rows only where each claim has a direct discriminating
assertion in that named property.

## Footgun re-triage

| ID | Follow-up finding | Status after follow-up 1 |
| --- | --- | --- |
| FG-E22-001 | Schedule laws lack reviewed normative prose. | **OPEN** — explicitly model/prose-pending above. |
| FG-E22-002 | `all`/`all_settled` order and fail-fast/capture were absent. | **CLOSED** by M13–M17. |
| FG-E22-003 | `with_scope` all-exit and nested release laws were absent. | **CLOSED** by M25–M27. |
| FG-E22-004 | Channel blocked-sender cancellation was absent. | **CLOSED** by M50. |
| FG-E22-005 | Semaphore bracket and abort laws were absent. | **CLOSED** by M60–M62. |
| FG-E22-006 | Broader normative prose outside the E22 review-target clusters still needs migration into this policy census. | **OPEN** — future census expansion; never misclassified as covered here. |
