# E22 law census

This census distinguishes laws normatively stated in public interfaces from
model laws selected by E22 but not yet stated in prose. A row is one behavioral
or algebraic claim. Several rows may cite one matrix property when that property
directly discriminates every cited claim.

The inventory-complete scope is exactly `effect.mli`, `schedule.mli`,
`channel.mli`, `queue.mli`, and `semaphore.mli`. Claims in those modules are
in the direct qcheck table, the verified external-suite table, or the explicit
dated-debt table; omitted and open-ended statuses are forbidden. This bootstrap
does **not** claim retrospective coverage of every other public interface. The
prospective repository rule applies without a debt escape hatch to new or
changed law-bearing prose in every `.mli`.

Direct qcheck census: **103 mli-stated claims**, **2 prose-pending model claims**,
**109 registered external claim clusters**, and **64 unique named qcheck properties** in
`test/laws/law_properties.ml`. Verified external named suites are registered
separately below and are not silently counted as qcheck coverage.

## Mli-stated laws

| ID | Claim | Exact normative span | Named qcheck property |
| --- | --- | --- | --- |
| M01 | `map` identity holds for total pure functions. | `lib/eta/effect.mli:152-155` | `map identity` |
| M02 | `map` composition holds for total pure functions. | `lib/eta/effect.mli:152-155` | `map composition` |
| M03 | `pure`/`bind` left identity holds for total continuations. | `lib/eta/effect.mli:165-168` | `pure/bind left identity` |
| M04 | `pure`/`bind` right identity holds for total continuations. | `lib/eta/effect.mli:165-168` | `pure/bind right identity` |
| M05 | `bind` is associative for total continuations. | `lib/eta/effect.mli:165-168` | `bind associativity` |
| M06 | `bind_error handler (fail error)` is `handler error`. | `lib/eta/effect.mli:265-266` | `bind_error left identity` |
| M07a | `bind_error` makes one recovery decision rather than handling every typed leaf. | `lib/eta/effect.mli:256-263` | `bind_error handles exactly once with the first typed failure in cause order` |
| M07b | `bind_error` chooses the first typed failure in cause order. | `lib/eta/effect.mli:260-263` | `bind_error handles exactly once with the first typed failure in cause order` |
| M07c | `bind_error` does not handle causes containing defects, interruption, or finalizer diagnostics. | `lib/eta/effect.mli:256-263` | `bind_error never handles defect interruption or finalizer diagnostics` |
| M08 | `fold` is coherent with success `map` and typed-error `bind_error`. | `lib/eta/effect.mli:282-291` | `fold coherence with map/bind_error` |
| M09 | `race` returns the first value. | `lib/eta/effect.mli:185-188` | `race returns the actual first distinctly tagged finite producer` |
| M10 | A cancelled race loser releases an actually held scoped resource. | `lib/eta/effect.mli:188-191` | `race loser cancellation releases an actually held scoped resource` |
| M11 | Successful `par left right` returns its pair in input position order, independent of completion order. | `lib/eta/effect.mli:202-205` | `par preserves pair input order across both observable completion directions` |
| M12 | `par` propagates the first child failure and cancels its sibling. | `lib/eta/effect.mli:203-205` | `par first observed failure cancels sibling tree and awaits cleanup` |
| M13 | `all` returns successful values in input order. | `lib/eta/effect.mli:211-214` | `all collects results in input order after reverse observable completion` |
| M14 | `all` cancels remaining children after the first observed failure. | `lib/eta/effect.mli:212-214` | `all first observed failure cancels siblings and awaits their finalizers` |
| M15 | `all` propagates the cause of the first observed failure. | `lib/eta/effect.mli:212-214` | `all first observed failure cancels siblings and awaits their finalizers` |
| M16 | `all_settled` captures every child failure as an `Error cause` value. | `lib/eta/effect.mli:216-220` | `all_settled captures every child cause and preserves input order` |
| M17 | `all_settled` returns child outcomes in input order. | `lib/eta/effect.mli:216-220` | `all_settled captures every child cause and preserves input order` |
| M18 | `map_par` returns mapped values in input order despite completion order. | `lib/eta/effect.mli:222-228` | `map_par preserves input order across both observable completion directions` |
| M19 | `map_par` cancels in-flight siblings after the first failure. | `lib/eta/effect.mli:227-228` | `map_par first failure cancels in-flight siblings and awaits scoped release` |
| M20 | `map_par ~max_concurrent` never exceeds its configured child-fiber bound. | `lib/eta/effect.mli:230-232` | `map_par never exceeds max_concurrent and reaches the bound when inputs suffice` |
| M21 | `finally` runs cleanup after success, typed failure, defect, and cancellation. | `lib/eta/effect.mli:524-528` | `finally exactly once across success/typed-failure/defect/cancellation exit kinds` |
| M22 | Cleanup failure after body success is reported as `Cause.Finalizer`. | `lib/eta/effect.mli:528-530` | `finally cleanup failure after success is a finalizer cause` |
| M23 | Cleanup failure after body failure is suppressed under the primary cause. | `lib/eta/effect.mli:530-532` | `finally cleanup failure is suppressed under a primary failure` |
| M24 | The lexical resource bracket releases when its body finishes with protected cleanup semantics. | `lib/eta/effect.mli:587-598,613-629` | `with_resource release across success/typed-failure/defect/cancellation exit kinds` |
| M24a | Bracket release failure after body success becomes `Cause.Finalizer`. | `lib/eta/effect.mli:592-598` | `with_resource release failure after body success becomes Cause.Finalizer` |
| M24b | Bracket release failure after body failure is suppressed under the primary cause. | `lib/eta/effect.mli:592-598` | `acquire_use_release release failure is suppressed under body failure` |
| M25 | `with_scope` releases resources in reverse acquisition order. | `lib/eta/effect.mli:638-643` | `scope reverse acquisition/release order` |
| M26 | `with_scope` finalizers run on success, typed failure, defect, and cancellation. | `lib/eta/effect.mli:641-643` | `with_scope releases registered resources on success typed failure defect and cancellation` |
| M27 | Nested scopes finish inner releases before the outer scope continues and releases. | `lib/eta/effect.mli:645-646` | `nested with_scope releases inner resources before outer continuation and finalizer` |
| M28 | A clock override restores after every exit kind. | `lib/eta/effect.mli:724-728` | `dynamic override restoration across each exit kind` |
| M29 | The innermost clock override wins and restores the exact outer clock. | `lib/eta/effect.mli:724-728` | `nested clock override uses innermost binding and restores each exact outer clock` |
| M30 | Clock overrides are isolated between `par` siblings. | `lib/eta/effect.mli:724-728` | `override sibling isolation under par` |
| M31 | A random-source override restores after every exit kind. | `lib/eta/effect.mli:735-739` | `dynamic override restoration across each exit kind` |
| M32 | The innermost random-source override wins and restores the exact outer source. | `lib/eta/effect.mli:735-740` | `nested random logger and tracer overrides use innermost bindings and restore exact outer observations` |
| M33 | Random-source overrides are isolated between `par` siblings. | `lib/eta/effect.mli:736-740` | `override sibling isolation under par` |
| M34 | A logger override restores after every exit kind. | `lib/eta/effect.mli:745-749` | `dynamic override restoration across each exit kind` |
| M35 | The innermost logger override wins and restores the exact outer sink. | `lib/eta/effect.mli:745-750` | `nested random logger and tracer overrides use innermost bindings and restore exact outer observations` |
| M36 | Logger overrides are isolated between `par` siblings. | `lib/eta/effect.mli:746-749` | `override sibling isolation under par` |
| M37 | A tracer override restores after every exit kind. | `lib/eta/effect.mli:754-758` | `dynamic override restoration across each exit kind` |
| M38 | The innermost tracer override wins and restores the exact outer tracer. | `lib/eta/effect.mli:754-761` | `nested random logger and tracer overrides use innermost bindings and restore exact outer observations` |
| M39 | Tracer overrides are isolated between `par` siblings. | `lib/eta/effect.mli:755-758` | `override sibling isolation under par` |
| M40 | Nested scoped log attributes accumulate outer-to-inner before per-call attributes. | `lib/eta/effect.mli:944-951` | `log pipeline applies stricter nested minimum then outer inner and call attrs before transform and sink` |
| M41 | Nested minimum log levels use the stricter effective threshold. | `lib/eta/effect.mli:953-962` | `log pipeline applies stricter nested minimum then outer inner and call attrs before transform and sink` |
| M42 | Log processing order is minimum filter, attributes, interceptors, then sink. | `lib/eta/effect.mli:970-979` | `log pipeline applies stricter nested minimum then outer inner and call attrs before transform and sink` |
| M43 | Nested log interceptors run outermost first and pass replacements inward. | `lib/eta/effect.mli:974-977` | `nested log interceptors run outermost first and pass replacements inward` |
| M44 | `Drop` stops the log pipeline before later interceptors and the sink. | `lib/eta/effect.mli:964-968,974-977` | `log interceptor Drop executes exactly its generated outer prefix and skips its suffix and sink` |
| M112 | `interruptible` outside a dynamic cancellation mask is identity. | `lib/eta/effect.mli:243-247` | `interruptible outside a mask is identity for generated finite effects` |
| M113 | An inner `uninterruptible` supersedes an outer restoration. | `lib/eta/effect.mli:243-247` | `uninterruptible interruptible uninterruptible equals uninterruptible for generated finite effects`; cancellation discrimination is registered by R103 |
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
| M63 | Terminal `Done` schedule metadata has exactly zero delay. | `lib/eta/schedule.mli:18-20` | `Schedule terminal Done metadata delay is exactly Duration.zero` |
| M64 | `and_then` tags first-phase outputs before second-phase outputs. | `lib/eta/schedule.mli:26-30` | `Schedule.and_then tags every first phase output before every second phase output` |
| M68 | `next` returns `Some metadata` exactly for `Continue` and `None` for terminal `Done`. | `lib/eta/schedule.mli:93-100` | `Schedule.next returns Some exactly for Continue and None exactly for terminal Done` |
| M69 | Channel creation rejects every nonpositive capacity. | `lib/eta/channel.mli:35-38` | `Channel create rejects every generated nonpositive capacity and accepts positive capacity` |
| M70 | Channel `try_send`/`try_recv` return immediately with exact empty, full, item, and close-boundary results. | `lib/eta/channel.mli:56-60` | `Channel try_send and try_recv return exact no-wait empty full item and close boundaries` |
| M71 | Queue `stats.size` and `size` equal `depth - waiting_receivers + waiting_senders`. | `lib/eta/queue.mli:47-51,95-97` | `Queue stats size formula and empty full shutdown queries match buffered and waiting pressure` |
| M72 | Queue `capacity` is `None` for unbounded mode and `Some capacity` for bounded modes. | `lib/eta/queue.mli:92-93` | `Queue stats size formula and empty full shutdown queries match buffered and waiting pressure` |
| M73 | Queue `is_empty` is exactly `size <= 0`. | `lib/eta/queue.mli:99-100` | `Queue stats size formula and empty full shutdown queries match buffered and waiting pressure` |
| M74 | Queue `is_full` is exactly bounded mode with `size >= capacity`. | `lib/eta/queue.mli:102-103` | `Queue stats size formula and empty full shutdown queries match buffered and waiting pressure` |
| M75 | Queue `is_shutdown` becomes true after shutdown commits. | `lib/eta/queue.mli:105-106` | `Queue stats size formula and empty full shutdown queries match buffered and waiting pressure` |
| M76 | Open Queue `take_up_to ~max:0` returns an empty list without draining. | `lib/eta/queue.mli:156-163` | `Queue take_up_to validates negative max and drains exactly zero or up to generated max` |
| M77 | Queue `take_up_to` drains at most `max` buffered values in order without waiting. | `lib/eta/queue.mli:156-160` | `Queue take_up_to validates negative max and drains exactly zero or up to generated max` |
| M78 | Queue `take_up_to` rejects negative `max`. | `lib/eta/queue.mli:165` | `Queue take_up_to validates negative max and drains exactly zero or up to generated max` |
| M79 | Semaphore creation starts with the requested permits and rejects nonpositive capacity. | `lib/eta/semaphore.mli:12-14,58-59` | `Semaphore validates bounds and try_acquire atomically decrements without barging queued waiters` |
| M80 | Successful `try_acquire n` atomically decrements available permits and failed acquisition does not decrement. | `lib/eta/semaphore.mli:16-20` | `Semaphore validates bounds and try_acquire atomically decrements without barging queued waiters` |
| M81 | `try_acquire` does not barge ahead of queued waiters. | `lib/eta/semaphore.mli:1-8,16-20` | `Semaphore validates bounds and try_acquire atomically decrements without barging queued waiters` |
| M82 | `try_acquire` rejects nonpositive and over-capacity requests. | `lib/eta/semaphore.mli:20` | `Semaphore validates bounds and try_acquire atomically decrements without barging queued waiters` |
| M83 | `acquire n` waits until enough permits exist and then atomically decrements by `n`. | `lib/eta/semaphore.mli:22-24` | `Semaphore wakes blocked permit waiters in FIFO order` |
| M84 | `acquire` rejects nonpositive and over-capacity requests. | `lib/eta/semaphore.mli:28` | `Semaphore validates bounds and try_acquire atomically decrements without barging queued waiters` |
| M85 | `release n` returns permits without blocking and wakes satisfiable waiters. | `lib/eta/semaphore.mli:30-32` | `Semaphore wakes blocked permit waiters in FIFO order` |
| M86 | `release` rejects nonpositive counts and releases above capacity. | `lib/eta/semaphore.mli:34-35` | `Semaphore validates bounds and try_acquire atomically decrements without barging queued waiters` |
| M87 | Channel `send` waits while full until a receive commits capacity. | `lib/eta/channel.mli:40-48` | `Channel send waits while full and recv waits while empty until the opposite operation commits` |
| M88 | Channel `recv` waits while empty until a send commits a value. | `lib/eta/channel.mli:50-54` | `Channel send waits while full and recv waits while empty until the opposite operation commits` |
| M89 | Channel close effect wrappers produce the same fence, drain, and reason as direct close. | `lib/eta/channel.mli:62-76` | `Channel close effect wrappers have the same fence drain and reason as direct close` |
| M90 | Queue close/shutdown effect wrappers produce the same transitions and reasons as direct operations through combined and producer/consumer views. | `lib/eta/queue.mli:174-185,193-239` | `Queue combined and view close or shutdown effect wrappers equal direct transitions` |
| M91 | `with_permits_or_abort` rejects every generated nonpositive or over-capacity request without changing counters. | `lib/eta/semaphore.mli:42-56` | `Semaphore.with_permits_or_abort rejects generated invalid requests and preserves exact counters` |
| M92 | `available` reports the exact current permit count. | `lib/eta/semaphore.mli:58-59` | `Semaphore.with_permits_or_abort rejects generated invalid requests and preserves exact counters` |
| M93 | `waiting` reports the exact current blocked-fiber count. | `lib/eta/semaphore.mli:61-62` | `Semaphore.with_permits_or_abort rejects generated invalid requests and preserves exact counters` |
| M94 | `cancelled_waiters` reports the cumulative cancelled-waiter count. | `lib/eta/semaphore.mli:64-65` | `Semaphore.with_permits_or_abort rejects generated invalid requests and preserves exact counters` |
| M106 | `Schedule.named label` adds `label` to `Schedule.pp` output. | `lib/eta/schedule.mli:70-72` | `Schedule.named changes only pp and emits no logs spans or metrics` |
| M107 | `Schedule.named` does not change stepping decisions. | `lib/eta/schedule.mli:70-72` | `Schedule.named changes only pp and emits no logs spans or metrics` |
| M109 | `Schedule.named` does not itself emit logs. | `lib/eta/schedule.mli:70-72` | `Schedule.named changes only pp and emits no logs spans or metrics` |
| M110 | `Schedule.named` does not itself emit spans. | `lib/eta/schedule.mli:70-72` | `Schedule.named changes only pp and emits no logs spans or metrics` |
| M111 | `Schedule.named` does not itself emit metrics. | `lib/eta/schedule.mli:70-72` | `Schedule.named changes only pp and emits no logs spans or metrics` |

## Registered external named suites

These claims are part of the complete `effect.mli`/`queue.mli` inventory, but
already have authoritative runtime/backend tests. Each pointer names the
executable test as registered with Alcotest (or the E13 shared adapter), not just
a helper or source file. They are registered here rather than duplicated as
qcheck optics.

| ID | Claim | Exact normative span | Named executable test and source pointer |
| --- | --- | --- | --- |
| R01 | `async` accepts only the first resolution. | `lib/eta/effect.mli:113-116` | `async one-shot first resolution wins` — `test/core_common/effect_async_shared.ml:323` |
| R02 | `async` may resolve synchronously during registration without deadlock. | `lib/eta/effect.mli:116` | `async synchronous resolution does not deadlock` — `test/core_common/effect_async_shared.ml:337-338` |
| R03 | Pending interruption runs an `async` canceler at most once. | `lib/eta/effect.mli:117-119` | `async canceler runs once on interruption` — `test/core_common/effect_async_shared.ml:324-325` |
| R04 | An `async` canceler is interruption-protected and interruption waits for it. | `lib/eta/effect.mli:117-120` | `async canceler survives pending interruption across yields` — `test/core_common/effect_async_shared.ml:326-327` |
| R05 | An `async` canceler never runs after resolution wins. | `lib/eta/effect.mli:118-119` | `async canceler never runs after resolution` — `test/core_common/effect_async_shared.ml:328-329` |
| R06 | An `async` canceler failure is a finalizer diagnostic suppressed under interruption. | `lib/eta/effect.mli:120` | `async canceler failure is suppressed under interruption` and `async canceler defect is suppressed under interruption` — `test/core_common/effect_async_shared.ml:333-336` |
| R07 | An exception raised by `async` registration becomes `Cause.Die`. | `lib/eta/effect.mli:121-122` | `async register raise becomes die` — `test/core_common/effect_async_shared.ml:330` |
| R08 | A registration exception wins even after synchronous resolution. | `lib/eta/effect.mli:121-122` | `async register raise wins after synchronous resume` — `test/core_common/effect_async_shared.ml:331-332` |
| R09 | Registration-to-parking `async` wakeups are not lost across resolution/cancellation orderings. | `lib/eta/effect.mli:123-124` | `async fixed same-domain resolution/cancel orderings preserve wakeups` — `test/core_common/effect_async_shared.ml:339-340` |
| R10 | js_of_ocaml uses the same `async` one-shot protocol. | `lib/eta/effect.mli:125-126` | E13 shared tests `async one-shot first resolution wins`; `async canceler runs once on interruption`; `async canceler survives pending interruption across yields`; `async canceler never runs after resolution`; `async register raise becomes die`; `async register raise wins after synchronous resume`; `async canceler failure is suppressed under interruption`; `async canceler defect is suppressed under interruption`; `async synchronous resolution does not deadlock`; `async fixed same-domain resolution/cancel orderings preserve wakeups` — definitions `test/core_common/effect_async_shared.ml:323-340`, native adapter `test/core_common/effect_async_common_suites.ml:47-55`, JS adapter `test/js_jsoo/test_eta_jsoo.ml:444-449,458-480` |
| R11 | `catch_some` has the same uncatchable-cause boundary as `bind_error`. | `lib/eta/effect.mli:272-274` | `catch_some skips uncatchable causes` — `test/core_common/effect_common_suites.ml:3584-3585` |
| R12 | `catch_some` inspects the first typed failure and runs a returned recovery. | `lib/eta/effect.mli:276-278` | `catch_some first composite recovery` — `test/core_common/effect_common_suites.ml:3578-3579` |
| R13 | `catch_some` preserves the exact composite typed cause when the handler returns `None`. | `lib/eta/effect.mli:276-278` | `catch_some non-match preserves composite` — `test/core_common/effect_common_suites.ml:3580-3581` |
| R14 | `or_else` leaves success unchanged without evaluating its fallback. | `lib/eta/effect.mli:293-300` | `or_else success noop` — `test/core_common/effect_common_suites.ml:3589-3590` |
| R15 | `or_else` runs its lazy fallback for catchable typed failure. | `lib/eta/effect.mli:293-299` | `or_else typed failure recovery` — `test/core_common/effect_common_suites.ml:3591-3592` |
| R16 | A failing `or_else` fallback becomes the resulting typed failure. | `lib/eta/effect.mli:293-300` | `or_else fallback failure` — `test/core_common/effect_common_suites.ml:3593-3594` |
| R17 | `or_else` does not handle defects, interruption, or finalizer diagnostics. | `lib/eta/effect.mli:298-300` | `or_else skips uncatchable causes` — `test/core_common/effect_common_suites.ml:3595-3596` |
| R18 | `when_ true` runs its source once and returns `Some`. | `lib/eta/effect.mli:302-309` | `when run and skip` — `test/core_common/effect_common_suites.ml:3603-3604` |
| R19 | `when_ false` does not evaluate its source and returns `None`. | `lib/eta/effect.mli:305-309` | `when run and skip` — `test/core_common/effect_common_suites.ml:3603-3604` |
| R20 | A source run by `when_` propagates typed failure, defect, interruption, and finalizer diagnostics. | `lib/eta/effect.mli:307-309` | `when source failure` — `test/core_common/effect_common_suites.ml:3605-3606` |
| R21 | `unless condition` is `when_ (not condition)`. | `lib/eta/effect.mli:311-314` | `unless inversion` — `test/core_common/effect_common_suites.ml:3613-3614` |
| R22 | `when_effect` evaluates its effectful predicate before deciding whether to run the source. | `lib/eta/effect.mli:316-323` | `when_effect laziness` — `test/core_common/effect_common_suites.ml:3611-3612` |
| R23 | `when_effect` propagates predicate failure or diagnostics without running the source. | `lib/eta/effect.mli:319-323` | `when_effect predicate failure` and `when_effect predicate diagnostics` — `test/core_common/effect_common_suites.ml:3607-3610` |
| R24 | `unless_effect` evaluates its predicate first and then behaves as `unless`, propagating predicate failure. | `lib/eta/effect.mli:325-330` | `unless_effect predicate first` — `test/core_common/effect_common_suites.ml:3615-3616` |
| R25 | `filter_or_fail` preserves a successful value accepted by its predicate. | `lib/eta/effect.mli:332-337` | `filter_or_fail true pass-through` — `test/core_common/effect_common_suites.ml:3617-3618` |
| R26 | `filter_or_fail` fails with `if_false value` when its predicate rejects. | `lib/eta/effect.mli:336-339` | `filter_or_fail false uses value` — `test/core_common/effect_common_suites.ml:3619-3620` |
| R27 | `filter_or_fail` preserves source typed failures, defects, interruption, and finalizer diagnostics. | `lib/eta/effect.mli:338-340` | `filter_or_fail source typed failure`, `filter_or_fail source defect`, `filter_or_fail source interruption`, and `filter_or_fail finalizer diagnostic` — `test/core_common/effect_common_suites.ml:3621-3628` |
| R28 | Exceptions from `filter_or_fail`'s predicate or `if_false` callback become unchecked defects. | `lib/eta/effect.mli:340-341` | `filter_or_fail callback raises become defects` — `test/core_common/effect_common_suites.ml:3629-3630` |
| R29 | `on_exit` receives the exact success, typed-failure, defect, or interruption exit. | `lib/eta/effect.mli:538-546` | `on_exit exact exits` and `on_exit cancellation exit` — `test/core_common/effect_common_suites.ml:3725-3728` |
| R30 | Successful `on_exit` cleanup preserves the original result. | `lib/eta/effect.mli:546-548` | `on_exit exact exits` — `test/core_common/effect_common_suites.ml:3725-3726` |
| R31 | Failed `on_exit` cleanup uses finalizer/suppressed-finalizer reporting. | `lib/eta/effect.mli:546-548` | `on_exit cleanup failure boundaries` — `test/core_common/effect_common_suites.ml:3729-3730` |
| R32 | `on_error` runs for typed, defect, composite, and suppressed-finalizer causes but not interruption-only causes. | `lib/eta/effect.mli:550-559` | `on_error exact causes and preservation` and `on_error skips interruption` — `test/core_common/effect_common_suites.ml:3733-3736` |
| R33 | Successful `on_error` cleanup preserves the original exit. | `lib/eta/effect.mli:558-559` | `on_error exact causes and preservation` — `test/core_common/effect_common_suites.ml:3733-3734` |
| R34 | Failed `on_error` cleanup follows `on_exit` finalizer reporting. | `lib/eta/effect.mli:558-559` | `selective cleanup failures suppressed` — `test/core_common/effect_common_suites.ml:3739-3740` |
| R35 | `on_interrupt` runs only for interruption-only causes. | `lib/eta/effect.mli:561-570` | `on_interrupt exact id and preservation` and `selective cleanup success noop` — `test/core_common/effect_common_suites.ml:3731-3738` |
| R36 | `on_interrupt` receives the first interrupt id from a composite interruption cause. | `lib/eta/effect.mli:568-570` | `on_interrupt exact id and preservation` — `test/core_common/effect_common_suites.ml:3737-3738` |
| R37 | Failed `on_interrupt` cleanup follows `on_exit` finalizer reporting. | `lib/eta/effect.mli:570` | `selective cleanup failures suppressed` — `test/core_common/effect_common_suites.ml:3739-3740` |
| R38 | `with_background` cancels its child when use returns. | `lib/eta/effect.mli:652-656` | `with_background cancels child` — `test/core_common/supervisor_common_suites.ml:343-344` |
| R39 | `with_background` cancels its child when use fails. | `lib/eta/effect.mli:654-656` | `with_background cancels child after use failure` — `test/core_common/supervisor_common_suites.ml:347-348` |
| R40 | `with_background` reports child cleanup failure. | `lib/eta/effect.mli:654-656` | `with_background reports cleanup failure` — `test/core_common/supervisor_common_suites.ml:345-346` |
| R41 | A failing daemon bypasses the typed result and emits a runtime diagnostic. | `lib/eta/effect.mli:658-668` | `daemon failure logs diagnostic` — `test/core_common/effect_resource_timeout_common_suites.ml:820-821` |
| R42 | Runtime drain waits for observably pending finite daemon work and its registered finalizer. | `lib/eta/effect.mli:666-668` | `daemon drain waits pending finalizer` — `test/core_common/effect_resource_timeout_common_suites.ml:818-819` |
| R43 | Bounded Queue offers wait while full. | `lib/eta/queue.mli:64-69` | `backpressure offer waits for capacity` — `test/core_common/core_common_suites.ml:1833-1834` |
| R44 | A full dropping Queue returns `false`/`Dropped` without admitting the value. | `lib/eta/queue.mli:71-76,112-116` | `drop new reports admission result` — `test/core_common/core_common_suites.ml:1829-1830` |
| R45 | A full sliding Queue admits the new value and drops the oldest buffered value. | `lib/eta/queue.mli:78-84,112-116` | `sliding keeps latest capacity` — `test/core_common/core_common_suites.ml:1823-1824` |
| R46 | Bounded, dropping, and sliding Queue constructors reject nonpositive capacity. | `lib/eta/queue.mli:64-84` | `bounded capacity rejects non-positive` — `test/core_common/core_common_suites.ml:1849-1850` |
| R47 | Unbounded Queue offers and ordered `offer_all` admissions succeed without leftovers. | `lib/eta/queue.mli:108-122` | `offer unbounded constructor` — `test/core_common/core_common_suites.ml:1815-1816` |
| R48 | `offer_all` preserves list order and returns partially admitted leftovers in order. | `lib/eta/queue.mli:118-122` | `offer_all partial leftovers ordered` — `test/core_common/core_common_suites.ml:1821-1822` |
| R49 | `send` reports `Dropped` when a dropping Queue rejects admission. | `lib/eta/queue.mli:124-128` | `send drop_new fails on rejection` — `test/core_common/core_common_suites.ml:1831-1832` |
| R50 | `try_offer` reports `Full` instead of waiting on a full bounded Queue. | `lib/eta/queue.mli:130-134` | `backpressure try_offer reports full` — `test/core_common/core_common_suites.ml:1835-1836` |
| R51 | A Queue sent token changes whenever a value is admitted and remains stable when no admission occurs. | `lib/eta/queue.mli:136-141` | `sent token changes only on admission` — `test/core_common/core_common_suites.ml:1819-1820` |
| R52 | Exceptions raised by `sync` remain unchecked defects, while runtime cancellation remains interruption. | `lib/eta/effect.mli:81-90` | `runtime exit fail die interrupt` — `test/core_common/effect_common_suites.ml:3702-3703` |
| R53 | `sync_result` maps `Ok` to success and `Error` to typed failure without catching exceptions. | `lib/eta/effect.mli:92-98` | `sync_result parity` — `test/core_common/effect_common_suites.ml:3647-3648` |
| R54 | `sync_option` maps `Some` to success and `None` to `if_none` failure without catching exceptions. | `lib/eta/effect.mli:100-108` | `sync_option parity` — `test/core_common/effect_common_suites.ml:3649-3650` |
| R55 | `map_par` rejects nonpositive `max_concurrent`. | `lib/eta/effect.mli:230-235` | `map_par rejects nonpositive max` — `test/core_common/effect_common_suites.ml:3801-3802` |
| R56 | `fold` maps success and catchable typed failure while preserving defects and interruption. | `lib/eta/effect.mli:280-287` | `fold recover shape` and `fold passes defect and interrupt` — `test/core_common/effect_common_suites.ml:3586,3601-3602` |
| R57 | Exceptions raised by either `fold` callback become unchecked defects. | `lib/eta/effect.mli:286-287` | `fold callback raises become defects` — `test/core_common/effect_common_suites.ml:3587-3588` |
| R58 | Queue post-commit waiter-resolution failure cannot roll back the active receive result. | `lib/eta/queue.mli:13-17` | `recv committed result survives wakeup failure` — `test/eta/run.ml:109-110` |
| R59 | Queue take, drain, and close commits remain authoritative when waking a sender is interrupted or its resolver raises. | `lib/eta/queue.mli:13-17` | `take_batch wakes interrupted admission`; `take_all wakes interrupted admission`; `try_recv wakes interrupted admission`; `recv wakes interrupted admission`; `close wakes interrupted sender`; `try_recv wakeup retry`; `recv wakeup retry`; `take_all wakeup retry`; `take_batch wakeup retry`; `close wakeup retry` — `test/eta/run.ml:114-133` |
| R60 | Queue shutdown remains committed when a waiter resolver raises. | `lib/eta/queue.mli:13-17` | `shutdown committed result survives wakeup failure` — `test/eta/run.ml:135-136` |
| R61 | Audit unions visible declared leaves without forcing bind continuations. | `lib/eta/effect.mli:34-40` | `audit declared leaves and preserve union`; `audit does not force bind continuation` — `test/core_common/effect_common_suites.ml:3562-3565` |
| R62 | `from_option` maps `Some` to success and `None` to `if_none` typed failure. | `lib/eta/effect.mli:66-71` | `from_option` — `test/core_common/effect_common_suites.ml:3644` |
| R63 | `flatten_result` maps successful `Ok`/`Error` payloads into Eta success/typed failure. | `lib/eta/effect.mli:73-79` | `flatten_result` — `test/core_common/effect_common_suites.ml:3645-3646` |
| R64 | `never` cannot succeed independently and is interruptible by timeout/cancellation. | `lib/eta/effect.mli:135-140` | `never times out and is interruptible` — `test/core_common/effect_common_suites.ml:3552-3553` |
| R65 | `die_message` creates a `Failure` defect outside the typed channel. | `lib/eta/effect.mli:142-146` | `die_message produces Failure defect`; `bind_error does not recover die_message` — `test/core_common/effect_common_suites.ml:3554-3557` |
| R66 | `tap` observes success, ignores the observer payload, preserves the source value, and propagates observer defect. | `lib/eta/effect.mli:175-180` | `tap observer runtime` — `test/core_common/effect_common_suites.ml:3572-3573` |
| R67 | Default `map_par` concurrency is eight. | `lib/eta/effect.mli:230` | `map_par default cap is eight` — `test/core_common/effect_common_suites.ml:3832-3833` |
| R68 | `uninterruptible` defers cancellation/finalization without converting interruption to typed failure. | `lib/eta/effect.mli:237-241` | `uninterruptible defers race cancellation`; `uninterruptible nested masks`; `uninterruptible blocking finalizer`; `uninterruptible timeout inside protected` — `test/core_common/effect_uninterruptible_common_suites.ml:114-121` |
| R69 | `discard` maps success to unit and preserves failed causes. | `lib/eta/effect.mli:343-348` | `discard` — `test/core_common/effect_common_suites.ml:3631` |
| R70 | `ignore_errors` maps success/typed-only failure to unit and preserves uncatchable causes. | `lib/eta/effect.mli:350-356` | `ignore_errors` — `test/core_common/effect_common_suites.ml:3632` |
| R71 | `to_result` materializes success/typed failure while leaving defects/finalizers failed. | `lib/eta/effect.mli:358-365` | `to_result` — `test/core_common/effect_common_suites.ml:3633` |
| R72 | `to_option` maps success/typed failure to `Some`/`None` and leaves defect/interruption failed. | `lib/eta/effect.mli:367-372` | `to_option` — `test/core_common/effect_common_suites.ml:3634` |
| R73 | `to_exit` materializes every success/failure category as an `Exit.t` success value. | `lib/eta/effect.mli:374-379` | `to_exit` — `test/core_common/effect_common_suites.ml:3635` |
| R74 | `map_error` maps typed leaves while preserving defects, interruption, and finalizer structure. | `lib/eta/effect.mli:381-387` | `map_error maps full cause`; `map_error preserves defects`; `map_error preserves interrupts` — `test/core_common/effect_common_suites.ml:3653-3658` |
| R75 | `or_die` converts typed leaves, preserves cause structure/other diagnostics, and preserves success. | `lib/eta/effect.mli:389-397` | `or_die converts typed failure`; `or_die converts composite typed failures`; `or_die preserves existing defect`; `or_die preserves suppressed finalizer`; `or_die success passthrough`; `or_die preserves interruption` — `test/core_common/effect_common_suites.ml:3659-3670` |
| R76 | `tap_error` observes typed failure, preserves it on observer success, skips uncatchable causes, and propagates observer failure normally. | `lib/eta/effect.mli:402-408` | `tap_error observes and rethrows`; `tap_error observer failure replaces original`; `tap_error skips defects and interrupts` — `test/core_common/effect_common_suites.ml:3685-3691` |
| R77 | `tap_cause` receives the full cause and preserves it after successful observation. | `lib/eta/effect.mli:410-414` | `tap_cause observes full cause` — `test/core_common/effect_common_suites.ml:3692-3693` |
| R78 | `tap_defect` receives the first defect and preserves the source cause after successful observation. | `lib/eta/effect.mli:416-420` | `tap_defect observes first defect` — `test/core_common/effect_common_suites.ml:3694-3695` |
| R79 | `retry` stops on success and retries only while predicate and schedule allow, using runtime delays. | `lib/eta/effect.mli:422-432` | `retry does nothing on initial success`; `retry stops when predicate rejects`; `retry recurs attempts initial plus retries`; `retry schedule uses virtual delays` — `test/core_common/effect_retry_repeat_common_suites.ml:1110-1115,1156-1159` |
| R80 | `retry` passes bare failures and the first typed failure of a catchable composite to its predicate and schedule. | `lib/eta/effect.mli:427-428,434-436` | `retry passes typed failures to schedule`; `retry composite passes first typed failure` — `test/core_common/effect_retry_repeat_common_suites.ml:1116-1119` |
| R81 | `retry` preserves causes with no typed failure, rejection, terminal exhaustion, and uncatchable composites; it does not retry runtime cancellation. | `lib/eta/effect.mli:434-437` | `retry skips composite uncatchable causes`; `retry composite rejection preserves original cause`; `retry composite exhaustion preserves original cause`; `retry does not catch defects`; `retry does not retry cancellation`; `retry does not retry interrupt`; `retry empty composite passes through` — `test/core_common/effect_retry_repeat_common_suites.ml:1120-1133,1194-1222` |
| R82 | `retry_or_else` success, predicate rejection, exhaustion, composite selection, uncatchable boundaries, delay, and fallback replacement follow the documented protocol. | `lib/eta/effect.mli:439-463` | `retry_or_else success`; `retry_or_else eventual success`; `retry_or_else predicate rejection fallback`; `retry_or_else first rejection has no output`; `retry_or_else exhausted fallback`; `retry_or_else fallback failure`; `retry_or_else composite typed failure`; `retry_or_else skips uncatchable causes`; `retry_or_else virtual delays` — `test/core_common/effect_retry_repeat_common_suites.ml:1175-1193` |
| R83 | Injected clock, fresh-counter, sleep, and timed success/failure semantics follow their documented runtime boundaries. | `lib/eta/effect.mli:465-496` | `sleep now timed runtime clock`; `timed preserves failures`; `fresh sequence is strictly increasing`; `fresh is unique under concurrency`; `replays across test runtimes`; `fresh_named uses fresh counter`; `sleep and now share monotonic timebase` — `test/core_common/effect_common_suites.ml:3636-3639,3789-3794`; `test/test/test_eta_test.ml:1164-1167`; `test/core_common/runtime_contract_common_suites.ml:346-347` |
| R84 | Root `acquire_release` finalizes across success/failure/defect with documented finalizer reporting and parallel ownership bridge. | `lib/eta/effect.mli:572-585` | `acquire release root finalizer`; `acquire release root failure finalizer`; `acquire release on failure`; `acquire release releases on defect`; `acquire release release failure after success`; `acquire release suppresses release failure`; `parallel acquire recipe partial failure`; `parallel acquire recipe release order`; `parallel acquire recipe ladder parity` — `test/core_common/effect_resource_timeout_common_suites.ml:814-817,824-831,853-858` |
| R85 | Lexical `acquire_use_release` releases each body across success, failure, defect, cancellation, and cleanup failure. | `lib/eta/effect.mli:587-598` | `acquire_use_release lexical bracket`; `acquire_use_release success`; `acquire_use_release typed failure releases`; `acquire_use_release defect releases`; `acquire_use_release releases on cancel`; plus M24a/M24b properties — `test/core_common/effect_resource_timeout_common_suites.ml:835-846` |
| R86 | `acquire_use_release_exit` observes success/failure/defect/interruption and reports release failure as documented. | `lib/eta/effect.mli:600-611` | `acquire_use_release_exit observes success failure and defect`; `acquire_use_release_exit observes interruption`; `acquire_use_release_exit release failure reporting` — `test/core_common/effect_common_suites.ml:3741-3748` |
| R87 | Default typed-error rendering and observability suppression behave on the registered trace/log/metric paths. | `lib/eta/effect.mli:675-691` | `statuses`; `suppress observability` — `test/core_common/observability_common_suites.ml:1289,1367-1368` |
| R88 | Dynamic capability overrides restore, nest, isolate, survive daemon capture, and govern their registered clock/random/tracer users. | `lib/eta/effect.mli:725-761` | M28–M39 properties; `restore on all exit kinds`; `fork inheritance`; `par sibling isolation both directions`; `daemon retains fork-time capabilities`; `in-flight real sleep ignores later override`; `clock controls sleep and timeout`; `random controls retry jitter`; `tracer override preserves open span` — `test/test/test_eta_test.ml:1131-1154` |
| R89 | `named` span success, kind, error rendering/defaulting, once-only rendering, and raising-printer behavior are executable. | `lib/eta/effect.mli:763-775` | `named span status ok`; `span kind`; `statuses`; `named error_pp domain string`; `error_pp render once`; `error_pp raise becomes defect` — `test/core_common/observability_common_suites.ml:1277-1296` |
| R90 | Registered annotation, event, result-attribute, link, context, baggage, sampling, and current-span behavior matches the documented paths. | `lib/eta/effect.mli:862-943` | `annotation order`; `die captures diagnostics`; `annotate_all die diagnostics`; `event records current span`; `with_result_attrs`; `withSpan links`; `par pending attrs links are fiber-local`; `in-memory tracer external trace id wins`; `trace context unsampled parent suppresses child`; `trace context par inherits baggage`; `in-memory tracer current span has valid ids` — `test/core_common/observability_common_suites.ml:1283-1322,1307-1308,1377-1388`; `test/otel_common/tracer_common_suites.ml:234` |
| R91 | Registered log Keep/Replace/Drop/order/fiber-local/error paths and level helpers match their documented pipeline behavior. | `lib/eta/effect.mli:964-1016` | M42–M44 properties; `intercept_log order and redaction`; `intercept_log drop short-circuits`; `intercept_log with_logger both orders`; `intercept_log raise becomes defect`; `intercept_log is fiber-local`; `log carries active span ids`; `annotate_logs merges per-call attrs`; `minimum log level drops lower records`; `log level helpers` — `test/core_common/observability_common_suites.ml:1327-1360`; `test/otel_common/logger_common_suites.ml:97-98` |
| R92 | Registered metric interception and counter/gauge/frequency/histogram/summary/timer helpers emit the documented measurements. | `lib/eta/effect.mli:1022-1103` | `intercept_metric enriches subtree`; `intercept_metric drop short-circuits`; `counter cumulative latest`; `counter monotonic sums`; `gauge latest`; `frequency counts categories`; `histogram explicit buckets`; `summary quantiles`; `timer records elapsed histogram` — `test/core_common/observability_common_suites.ml:1359-1362`; `test/otel_common/metrics_common_suites.ml:302-314` |
| R93 | `fn`, `collect_names`, and audit flags follow registered location/attribute/name/order/visible-union behavior. | `lib/eta/effect.mli:1141-1175` | `fn records location`; `annotate_all and fn attrs`; `collect_names`; `audit declared leaves and preserve union`; `audit does not force bind continuation`; `expert audit declarations and inheritance` — `test/core_common/observability_common_suites.ml:1280-1282`; `test/core_common/effect_common_suites.ml:3561-3567` |
| R94 | A `Continue` metadata delay is the sleep before retry recurrence. | `lib/eta/schedule.mli:18-19` | `retry schedule uses virtual delays` — `test/core_common/effect_retry_repeat_common_suites.ml:1158-1159` |
| R95 | Starting a jittered schedule draws from the supplied random capability. | `lib/eta/schedule.mli:78-84` | `jittered uses random capability` — `test/core_common/duration_schedule_common_suites.ml:629-630` |
| R97 | Queue cross-domain use and sender/receiver owner-domain resumption are executable. | `lib/eta/queue.mli:19-20` | `allows cross-domain sync use`; `backpressure sender wakeup stays on owner domain`; `receiver wakeup stays on owner domain`; `foreign try_offer wakes owner receiver` — `test/eta/run.ml:91-104` |
| R98 | Queue `take`, `poll`, and `take_all` blocking/no-wait/item/order semantics are executable. | `lib/eta/queue.mli:143-154` | `recv waits instead of empty`; `send recv close`; `try_recv wakes interrupted admission`; `backpressure try_offer reports full`; `take_all and take_up_to drain` — `test/eta/run.ml:118-119,141-142`; `test/core_common/core_common_suites.ml:1806-1807,1835-1836,1845-1846` |
| R99 | `timeout_as` follows timeout ownership/cancellation/finalizer boundaries and maps only its own expiry to the supplied typed error. | `lib/eta/effect.mli:498-502` | `timeout_as exact error row`; `timeout_as maps delayed eff`; `timeout_as nested maps outer timeout`; `timeout_as preserves simultaneous failure`; `timeout_as preserves cancelled finalizer` — `test/core_common/effect_resource_timeout_common_suites.ml:873-882` |
| R100 | `repeat` evaluates once before stepping, follows schedule delays and outputs, and interruption stops the loop. | `lib/eta/effect.mli:503-515` | `repeat schedule`; `repeat recurs zero runs body once`; `repeat passes successful values to schedule`; `repeat schedule uses virtual delays`; `repeat fixed cadence differs from spaced`; `repeat fixed overrun has no pileup`; `repeat timeout interrupts loop` — `test/core_common/effect_retry_repeat_common_suites.ml:1134-1147` |
| R101 | `forever` repeats successes and stops on typed failure, defect, interruption/timeout, or finalizer diagnostic without succeeding. | `lib/eta/effect.mli:517-523` | `forever repeats until timeout`; `forever stops on typed failure`; `forever stops on defect`; `forever stops on finalizer diagnostic` — `test/core_common/effect_retry_repeat_common_suites.ml:1148-1155` |
| R102 | Inside a dynamic mask, `interruptible` restores parent cancellation at a blocking checkpoint. | `lib/eta/effect.mli:243-247` | `interruptible cancel during restored block wakes waiter`; `interruptible cancel at restored checkpoint is delivered` — shared definitions and native/jsoo registration `test/core_common/effect_interruptible_shared.ml:99-152,531-536` |
| R103 | Cancellation-mask nesting is innermost-wins on both backends. | `lib/eta/effect.mli:243-247` | `interruptible mask-stack law inner uninterruptible wins`; `interruptible nested mask innermost restore wins` — shared definitions and native/jsoo registration `test/core_common/effect_interruptible_shared.ml:220-297,541-544` |
| R104 | Pending interruption is delivered at restoration entry and at the successful-exit edge, with generated entry races losing no wakeup. | `lib/eta/effect.mli:246-247` | `interruptible pending cancellation raises at restore entry`; `interruptible cancel between restore and exit hits successful boundary`; `interruptible generated cancel-mask-entry races lose no wakeup` — shared definitions and native/jsoo registration `test/core_common/effect_interruptible_shared.ml:78-97,154-218,529-540` |
| R105 | One cancellation is observed at most once by an interruptible region. | `lib/eta/effect.mli:246-247` | `interruptible competing cancellation sources deliver once` — shared definition and native/jsoo registration `test/core_common/effect_interruptible_shared.ml:299-328,545-546` |
| R106 | Repeated `interruptible` inside an already-restored region is identity. | `lib/eta/effect.mli:243-247` | `repeated interruptible in restored region is identity` — shared definition and native/jsoo registration `test/core_common/effect_interruptible_shared.ml:117-134,533-534` |
| R107 | `interruptible` cannot restore cancellation from `finally` cleanup or a registered finalizer. | `lib/eta/effect.mli:249-250` | `interruptible is forbidden in finalizers`; `interruptible is forbidden in registered finalizers` — shared definitions and native/jsoo registration `test/core_common/effect_interruptible_shared.ml:330-416,547-550` |
| R108 | Cancellation masks cover forked children, while restoration remains fiber-local and structured fail-fast still interrupts the child scope. | `lib/eta/effect.mli:249-250` | `cancellation mask covers forked children`; `forked interruptible child preserves fail-fast` — shared definitions and native/jsoo registration `test/core_common/effect_interruptible_shared.ml:418-452,513-524,551-554` |
| R109 | Restoration and cleanup-forbidden state do not outlive their owning fiber through daemons. | `lib/eta/effect.mli:249-250` | `daemon drops restore binding after mask`; `daemon drops cleanup-forbidden binding` — shared definitions and native/jsoo registration `test/core_common/effect_interruptible_shared.ml:454-511,555-558` |
| R110 | Default runtime locals cross forks, while `Fiber_local` bindings are absent in forked children and daemons. | `lib/eta/runtime_contract.mli:239-241` | `runtime contract local inheritance kinds` — native `test/runtime_common/runtime_common_suites.ml:892-931,1271-1272`; jsoo `test/js_jsoo/test_eta_jsoo.ml:171-212,518-519` |

## Model laws (prose pending)

These E22 bootstrap laws are executable but are not presented as mli-stated
claims. Promotion into `schedule.mli` needs a separately reviewed statement of
valid constructor domains; until then their provenance is explicit.

| ID | Model claim | Declaration location | Named qcheck property | Prose status |
| --- | --- | --- | --- | --- |
| P01 | Valid exponential, fibonacci, and nonnegative linear schedules produce exactly the requested prefix of nondecreasing delays. | `lib/eta/schedule.mli:32-39` | `monotone delay sequences for valid exponential/fibonacci/linear schedules` | PENDING (`FG-E22-001`) |
| P02 | `recurs n` emits exactly `n` `Continue` steps before `Done`. | `lib/eta/schedule.mli:18-24,32,86-100` | `recurs n step count` | PENDING (`FG-E22-001`) |

## Census totals

| Mli | Direct qcheck claims | Registered external rows | Model claims | Covered registry rows |
| --- | ---: | ---: | ---: | ---: |
| `lib/eta/effect.mli` | 50 | 92 | 0 | 142 |
| `lib/eta/schedule.mli` | 8 | 2 | 2 | 10 |
| `lib/eta/channel.mli` | 12 | 0 | 0 | 12 |
| `lib/eta/queue.mli` | 16 | 14 | 0 | 30 |
| `lib/eta/semaphore.mli` | 17 | 0 | 0 | 17 |
| `lib/eta/runtime_contract.mli` | 0 | 1 | 0 | 1 |
| **Total covered** | **103** | **109** | **2** | **212** |

The executable contains 64 unique properties in total. Matrix properties cover
multiple one-claim rows only where each claim has a direct discriminating
assertion in that named property.

## Explicit dated claim debt inside the complete inventory

These are not counted as covered. They are listed because the bootstrap policy
must not turn missing historical executables into a false completeness claim.
No new or changed prose may use this table as an escape from same-change testing.

| ID | Exact uncovered claim cluster | Owner, follow-up, deadline |
| --- | --- | --- |
| CD-E22-001 | Conservative audit over-reporting, visible-only false flags, and dishonest `Expert.make` declarations — `effect.mli:42-47,1170-1175`. | Eta core maintainers; add named audit adversarial matrix; **2026-08-15**. |
| CD-E22-002 | A real cooperative `yield` scheduling handoff — `effect.mli:128-133`. | Eta runtime maintainers; add two-fiber ordering test; **2026-08-15**. |
| CD-E22-003 | `tap` observer typed failure, interruption, resource lifecycle, and observability propagation — `effect.mli:178-180`. | Eta core maintainers; extend named tap matrix; **2026-08-15**. |
| CD-E22-004 | `uninterruptible` does not catch defects — `effect.mli:240-241`. | Eta runtime maintainers; add defect passthrough test; **2026-08-15**. |
| CD-E22-005 | Remaining conversion/error-observer edges: `to_result` interruption, `to_option` finalizer, nested `map_error`, raising `or_die`, first-composite `tap_error`, and failing `tap_cause`/`tap_defect` observers — `effect.mli:361-420`. | Eta core maintainers; extend conversion/observer matrix; **2026-08-31**. |
| CD-E22-006 | `retry_or_else` current-runtime predicate, schedule-policy, and fallback defect/interruption/finalizer failure paths — `effect.mli:445-463`. | Eta scheduling maintainers; extend the `retry_or_else` shared-suite failure matrix; **2026-08-31**. |
| CD-E22-007 | Distinct-domain `fresh` collision allowance, exhaustion failure, monotonic-vs-civil clock discrimination, and timed finalizer preservation — `effect.mli:465-496`. | Eta runtime maintainers; add controllable-counter/domain tests; **2026-09-15**. |
| CD-E22-008 | Cancellation checkpoint inside protected `finally` cleanup — `effect.mli:528`. | Eta resource maintainers; add protected-cleanup barrier test; **2026-08-15**. |
| CD-E22-009 | Exit-aware release seeing body-scope finalizer failure and full `with_resource_exit` alias equivalence — `effect.mli:608-611,631-636`. | Eta resource maintainers; add exit-bracket matrix; **2026-08-31**. |
| CD-E22-010 | `with_error_pp` scope/once/raising behavior and suppression preserving errors/resources/diagnostics — `effect.mli:675-691`. | Eta observability maintainers; add wrapper-specific matrix; **2026-08-31**. |
| CD-E22-011 | Random fork inheritance and complete clock-governed-user matrix — `effect.mli:725-743`. | Eta runtime maintainers; extend capability inheritance matrix; **2026-08-31**. |
| CD-E22-012 | Remaining tracing edges: default span kind, lazy annotation/enabled checks, no-span events, composite result attrs, external-parent equivalence, tracestate/current-context absence — `effect.mli:771-775,872-943`. | Eta observability maintainers; extend trace-context suite; **2026-09-15**. |
| CD-E22-013 | Metric interceptor raise, raw/batched/lazy update behavior, runtime-without-meter behavior, and timer success/defect/interruption/finalizer preservation — `effect.mli:1022-1127`. | Eta metrics maintainers; extend metric matrix; **2026-09-15**. |
| CD-E22-014 | `fn ~error_pp`, all continuation boundaries for `collect_names`, and named deterministic `describe` snapshot contracts — `effect.mli:1141-1185`. | Eta introspection maintainers; name snapshot executable and add continuation matrix; **2026-09-15**. |
| CD-E22-015 | Portable-runtime worker-safe random requirement for jitter — `schedule.mli:82-84`. | Eta scheduling maintainers; add worker-domain capability test; **2026-09-15**. |
| CD-E22-016 | Queue payload non-copy/caller representation responsibility — `queue.mli:20-22`. | Eta queue maintainers; classify as non-executable ownership guidance or add identity/cross-domain test; **2026-08-31**. |
| CD-E22-017 | Documented interceptor allocation/fast-path claims — `effect.mli:965-968,980-982,1025-1027`. | Eta performance maintainers; add allocation gate or remove normative performance prose; **2026-09-30**. |
| CD-E22-018 | `Effect.Expert` capability declarations, inherited-child footprint, background implication, and helper/runtime-contract semantics — `effect.mli:794-856`. | Eta runtime-extension maintainers; add named Expert contract matrix; **2026-09-15**. |
| CD-E22-019 | Race-loser resource release after the loser has completed before its value is discarded — `effect.mli:188-191`. | Eta concurrency maintainers; add completed-loser ownership test; **2026-08-31**. |
| CD-E22-020 | Cancellation protection through an internal checkpoint during lexical bracket release — `effect.mli:594-598`. | Eta resource maintainers; add protected lexical-release barrier test; **2026-08-31**. |
| CD-E22-021 | Channel same-domain portability fence and preallocated-storage claim — `channel.mli:3-8`. | Eta primitive maintainers; add backend/structural conformance test or reclassify prose; **2026-09-15**. |
| CD-E22-023 | `repeat` stops and propagates the first typed/defect/finalizer source failure — `effect.mli:515`. | Eta scheduling maintainers; add failing-source repeat matrix; **2026-08-31**. |

## Footgun and debt re-triage

| ID | Follow-up finding | Status after follow-up 2 |
| --- | --- | --- |
| FG-E22-001 | Schedule model laws lack reviewed normative prose. | **DATED MODEL-PROSE DEBT** — owner: Eta API maintainers; follow-up: review constructor domains and either promote or remove P01/P02 by **2026-08-31**. Executable model coverage exists today. |
| FG-E22-002 | `all`/`all_settled` order and fail-fast/capture were absent. | **CLOSED** by M13–M17. |
| FG-E22-003 | `with_scope` all-exit and nested release laws were absent. | **CLOSED** by M25–M27. |
| FG-E22-004 | Channel blocked-sender cancellation was absent. | **CLOSED** by M50. |
| FG-E22-005 | Semaphore bracket and abort laws were absent. | **CLOSED** by M60–M62. |
| FG-E22-006 | Required existing `effect.mli` and `queue.mli` clusters were omitted from the map. | **REGISTERED/CLOSED** by R01–R51; every pointer names a real executable test. |
| D-E22-001 | Core interfaces `lib/eta/{capabilities,cause,duration,exit,log_level,logger,meter,mutable_ref,pool,portable_queue,promise,pubsub,random,resource,runtime,runtime_contract,runtime_supervisor,sampler,string_helpers,supervisor,sync_lock,syntax,trace_context,tracer}.mli`. | **DATED COVERAGE DEBT** — owner: Eta core maintainers; follow-up: claim-by-claim core registry by **2026-08-15**. |
| D-E22-002 | HTTP interfaces under `lib/http/`, `lib/http_eio/`, `lib/http_js/`, `lib/http_service/`, `lib/http_service_eio/`, and `lib/http_tls_openssl/`. | **DATED COVERAGE DEBT** — owner: Eta HTTP maintainers; follow-up: HTTP registry linked to interop/conformance suites by **2026-08-31**. |
| D-E22-003 | AI/integration interfaces under `lib/ai/`, `lib/exa/`, `lib/otel/`, and `lib/redacted/`. | **DATED COVERAGE DEBT** — owner: Eta integration maintainers; follow-up: integration registry by **2026-09-15**. |
| D-E22-004 | Signal interfaces under `lib/signal/`. | **DATED COVERAGE DEBT** — owner: Eta signal maintainers; follow-up: signal law registry by **2026-08-31**. |
| D-E22-005 | Remaining extension interfaces under `lib/{blocking,cache,eio,js,js_stream,js_test,jsoo,linux_input,par,router,schema,schema_test,sql,sql_driver,sql_dsl,stream,test,utop}/`. | **DATED COVERAGE DEBT** — owner: owning Eta package maintainers; follow-up: package-by-package registry by **2026-09-30**. |
