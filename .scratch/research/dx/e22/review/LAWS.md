# E22 initial law inventory

Census: **22 laws** across **5 mli files**, each requiring one named qcheck
property in `test/laws/law_properties.ml`. Exit-kind matrices are generated
cases within a law, not extra census rows.

| # | Name | Statement | Mli source | Qcheck property |
| ---: | --- | --- | --- | --- |
| 1 | map identity | `map id m` is observationally equivalent to `m`. | `lib/eta/effect.mli:148-150` | `map identity` |
| 2 | map composition | `map f (map g m)` is observationally equivalent to `map (fun x -> f (g x)) m`. | `lib/eta/effect.mli:148-150` | `map composition` |
| 3 | bind associativity | `bind g (bind f m)` is observationally equivalent to `bind (fun x -> bind g (f x)) m`. | `lib/eta/effect.mli:152-163` | `bind associativity` |
| 4 | bind left identity | `bind f (pure x)` is observationally equivalent to `f x`. | `lib/eta/effect.mli:58,152-163` | `pure/bind left identity` |
| 5 | bind right identity | `bind pure m` is observationally equivalent to `m`. | `lib/eta/effect.mli:58,152-163` | `pure/bind right identity` |
| 6 | bind_error left identity | `bind_error h (fail e)` is observationally equivalent to `h e`. | `lib/eta/effect.mli:59,233-244` | `bind_error left identity` |
| 7 | fold coherence | `fold ~ok ~error m` agrees with success `map` plus typed-failure `bind_error`. | `lib/eta/effect.mli:233-265` | `fold coherence with map/bind_error` |
| 8 | par pair order | Successful `par left right` returns `(left_value, right_value)`, independent of completion order. | `lib/eta/effect.mli:192-199` | `par pair input order` |
| 9 | par fail-fast | The first child failure cancels a pending sibling, waits through its cleanup, and propagates the failure. | `lib/eta/effect.mli:192-199` | `par fail-fast cancels pending sibling and waits for observable finalizer` |
| 10 | map_par input order | `map_par` returns values in input order under generated interleavings. | `lib/eta/effect.mli:212-225` | `map_par input order across interleavings` |
| 11 | race loser cancellation | A winning `race` cancels a genuinely pending loser and completes its scoped cleanup before returning. | `lib/eta/effect.mli:175-190` | `race pending-loser cancellation` |
| 12 | finally all exits exactly once | `finally` runs cleanup exactly once after success, typed failure, defect, and cancellation. | `lib/eta/effect.mli:494-506` | `finally exactly once across success/typed-failure/defect/cancellation exit kinds` |
| 13 | scope LIFO | A scope releases registered resources in reverse acquisition order. | `lib/eta/effect.mli:608-620` | `scope reverse acquisition/release order` |
| 14 | with_resource all exits | `with_resource` releases its resource after success, typed failure, defect, and cancellation. | `lib/eta/effect.mli:562-599` | `with_resource release across success/typed-failure/defect/cancellation exit kinds` |
| 15 | Channel close fence | First close wins; future sends fail, buffered values drain FIFO, then receivers observe the close reason. | `lib/eta/channel.mli:8-15,44-69` | `Channel graceful close fence/drain/reason ordering` |
| 16 | Semaphore cancellation safety | Cancelling a blocked acquire removes its waiter and consumes no permits. | `lib/eta/semaphore.mli:22-28` | `Semaphore waiting-cancellation safety/no permit consumption` |
| 17 | Queue close/error ordering | First graceful close reason wins; buffered values remain ordered and drain before the close/error reason. | `lib/eta/queue.mli:6-17,167-179` | `Queue graceful close/error ordering` |
| 18 | schedule monotone delays | Valid exponential, fibonacci, and nonnegative linear schedules produce nondecreasing delays. | E22 bootstrap model law assigned to declarations at `lib/eta/schedule.mli:36-43`; the mli does not yet state monotonicity in prose. | `monotone delay sequences for valid exponential/fibonacci/linear schedules` |
| 19 | recurs step count | `recurs n` continues exactly `n` times before its terminal `Done` step. | E22 bootstrap model law assigned to `lib/eta/schedule.mli:22-28,36,125-140`; the mli does not yet define `n` in prose. | `recurs n step count` |
| 20 | override restoration | Clock, random, logger, and tracer overrides are restored after success, typed failure, defect, and interruption. | `lib/eta/effect.mli:694-731` | `dynamic override restoration across each exit kind` |
| 21 | override sibling isolation | An override in one `par` child does not leak into its sibling. | `lib/eta/effect.mli:694-731` | `override sibling isolation under par` |
| 22 | log pipeline order | Log processing order is minimum-level filter, scoped/per-call attributes, interceptors, then sink. | `lib/eta/effect.mli:914-952` | `log pipeline order filter -> attrs -> transform -> sink` |

## Laws per mli

| Mli | Laws |
| --- | ---: |
| `lib/eta/effect.mli` | 17 |
| `lib/eta/schedule.mli` | 2 |
| `lib/eta/channel.mli` | 1 |
| `lib/eta/queue.mli` | 1 |
| `lib/eta/semaphore.mli` | 1 |
| **Total** | **22** |

## Follow-up footguns outside the bootstrap 22

The objective gates promotion on the initial inventory, not an instantly
exhaustive conversion of every existing contract sentence. Maintainer review
found these gaps; policy-compliant follow-up must inventory and test them rather
than silently treating the bootstrap census as complete.

| ID | Gap | Source / next evidence |
| --- | --- | --- |
| FG-E22-001 | Schedule constructor declarations do not yet state the two bootstrap laws in prose. | Decide exact valid domains, then add reviewed mli wording without broadening behavior. |
| FG-E22-002 | `all` input ordering/fail-fast and `all_settled` input ordering are law-bearing prose outside the bootstrap rows. | `lib/eta/effect.mli:201-210`; add generated list/interleaving properties. |
| FG-E22-003 | `with_scope` says finalizers run on all four exit kinds; the bootstrap tests LIFO only. | `lib/eta/effect.mli:608-620`; add an all-exit property. |
| FG-E22-004 | Channel says cancelling a blocked sender removes its slot and increments its counter. | `lib/eta/channel.mli:44-48`; add a blocked-sender cancellation property distinct from close wakeup. |
| FG-E22-005 | Semaphore bracket/abort prose states all-exit release and abort-result laws beyond blocked-acquire safety. | `lib/eta/semaphore.mli:37-56`; add exit-matrix and abort-race properties. |
