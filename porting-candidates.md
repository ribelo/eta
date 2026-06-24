# Small Behaviors Worth Porting — effect-smol / ZIO → Eta

A living catalogue of **small, behavior-level** features that exist in
`.reference/effect-smol` (and sometimes `.reference/zio`) and that Eta either
lacks or only partially covers. The big architectural pieces (typed failures,
causes, exits, structured concurrency, schedules, scoped resources,
observability dispatch, streams) are already ported. This file focuses on the
"papercut" gaps — the little behaviors a user notices is missing once they live
in the library day to day.

## How to read this

Each entry has a **verdict**:

- **PORT** — clear win, fits Eta's identity, low surface cost. Recommend doing.
- **CONSIDER** — plausibly valuable but has a design question or a minimalism
  tension; worth a human decision before building.
- **LEAVE-TO-HUMAN** — I am genuinely unsure it belongs in Eta; flagged so a
  human can decide. Often these are convenience sugar that may conflict with
  Eta's "applications own state" minimalism.
- **OUT-OF-SCOPE** — listed so we don't re-discover it; deliberately not Eta's
  job (general data-structure libraries, etc.).

Eta identity constraints kept in mind throughout (from `AGENTS.md`):
applications own state; Eta owns effect description/interpretation; no fallback
shims; break loudly; install-only-what-you-use package boundaries.

This is **not** decisive. Where I write PORT I still expect a human to sanity
check against Eta's taste.

---

## TL;DR — priority ranking

A tiered shortlist so a human can act without reading all 60 entries. Tiers
reflect value × confidence × fit-with-Eta, not effort.

**Tier 1 — clear wins, directly answer the prompt (recommend doing):**
- None currently open after the adoption pass.

**Adopted since this catalogue was written:**
- 1.1 Console logger sinks (pretty / logfmt / json).
- 1.2 Level-filtered / leveled console logger.
- 1.4 Console span + metric exporter.
- 1.5 `Cause`/`Exit` inspection helpers.
- 1.7 full distribution metric surface.
- 1.8 level-named log helpers.
- 2.1 `Effect.result` / `option` / `exit`.
- 2.2 `Effect.ignore`.
- 2.5 `Effect.timed`.
- 2.6 `Effect.sleep` / `now`.
- 2.9 effectful / defect-aware `tap` observers.
- 2.16 selective cleanup `on_interrupt` / `on_error`.
- 2.17 `Effect.yield`.
- 2.18 `Effect.from_option`.
- 2.3 `orElse` / `orElseSucceed` / `orDie`.
- 3.1 `Schedule.fibonacci`.
- 5.1 `Duration.humanize`.
- 7.1 `Stream.tap` / `tap_error`.
- 7.6 `Stream.run_for_each` / `run_fold` / `run_count`.
- 8.1 exit-aware finalizer (`acquire_use_release_exit`).
- 8.4 scoped log annotations (`Effect.annotate_logs`).

**Tier 2 — small, high-frequency effect ergonomics (likely worth it):**
- None currently open.

**Tier 3 — real behavior, bigger or design-sensitive (human call):**
- 6.7 `SubscriptionRef`.
- 2.13 error-accumulating `validate_all`.

**Tier 4 — taste/sugar or niche (default: skip unless a consumer asks):**
- 2.7 `iterate`/`loop`; 2.18 `flip`/`zip`/`race_first`;
  4.x random conveniences; 5.2 sub-ms precision.

**Already decided / don't reopen without a protocol trigger:** Deferred (6.1),
Latch (6.2) — rejected in `journal.md` V-CDv2/V-CDv4.

**Notable big-but-missing (out of "small things" scope, flagged anyway):** STM /
transactional refs (6.9) — present in both references, absent in Eta; likely a
deliberate omission to confirm + document.

**Already covered (not gaps):** see §10.

---

## 1. Observability / Logging (the motivating example)

Eta previously only had in-memory/no-op logging and OTLP telemetry export. The
current code now covers the local-debug slice too: `lib/eta/logger.mli` exposes
human-readable console log sinks, and `lib/otel/eta_otel.mli` exposes
`Eta_otel.Terminal` for terminal spans and metrics.

### 1.1 Console logger sinks — **ADOPTED**
effect-smol: `Logger.consolePretty`, `consoleLogFmt`, `consoleStructured`,
`consoleJson`, plus the format functions `formatSimple`, `formatLogFmt`,
`formatStructured`, `formatJson`.

Eta now exposes the no-dependency core slice in `lib/eta/logger.mli`:
`format_pretty`, `format_logfmt`, `format_json`, `console_pretty`,
`console_logfmt`, and `console_json`. `Capabilities.log_record` already carries
`level`, `body`, `ts_ms`, `attrs`, `trace_id`, and `span_id`; the console sinks
render those records and route `Error`/`Fatal` to stderr. Covered by
`test/core_common/logger_common_suites.ml`.

### 1.2 Level-filtered / leveled console — **ADOPTED**
effect-smol: `Logger.withLeveledConsole` (route by level: errors→stderr,
warn→console.warn, etc.) and a minimum-level filter.

Eta now exposes `Logger.with_min_level` and the console sinks accept
`?min_level`. `Logger.console_pretty`, `console_logfmt`, and `console_json`
route `Error`/`Fatal` to stderr and all other levels to stdout.

### 1.3 Batched logger wrapper — **DEFERRED**
effect-smol: `Logger.batched` (buffer records and flush on an interval/size).
Behavior: wrap a logger so writes are coalesced.

Eta should not add this as a generic logger combinator yet. This is present in
Effect, but the local ZIO core reference does not expose an equivalent generic
`ZLogger` batching combinator, so it is not a two-reference parity gap. Eta's
OTLP exporter already owns batching where batching matters operationally:
bounded queues, exporter-owned runtime work, and explicit `flush`/`shutdown`.
The core console sinks should stay synchronous and flushed for deterministic
local debugging. Reopen only for a concrete non-OTLP sink, such as file or
remote logging, where the batching lifecycle belongs to that sink.

### 1.4 Console / stdout span + metric exporter — **ADOPTED**
ZIO/Effect both ship a "print telemetry to terminal" debug exporter.

Eta now exposes the same local-debug slice in `lib/otel/eta_otel.mli` as
`Eta_otel.Terminal`. It creates terminal tracer and meter capabilities that
render completed spans and metric points as deterministic single-line records;
successful spans and metrics go to stdout, failed/cancelled spans go to stderr.
Covered by `test/otel_common/terminal_common_suites.ml` and
`test/otel/test_terminal.ml`.

### 1.5 `Cause` / `Exit` inspection + pretty rendering — **ADOPTED / mostly covered**
effect-smol `Cause.ts`: `pretty`, `prettyErrors`, `squash`, `hasFails`/`findFail`,
`findError`, `hasDies`/`findDie`/`findDefect`, `hasInterrupts`/`findInterrupt`,
`interruptors`, `annotate`. `Exit.ts`: `match`, `map`, `mapError`, `mapBoth`,
`getOrElse`, `getSuccess`, `getCause`, `isSuccess`/`isFailure`, `asVoid`.

Eta now covers the substantial behavior: `Cause.failures`, `defects`,
`interruptors`, `squash`, and `pretty`, plus `Exit.match_`, `map`, `map_error`,
`map_both`, `get_success`, `get_cause`, `get_or_else`, `as_unit`, and
`pretty`. That closes the real inspection/debuggability gap without requiring
manual recursive cause walks.

Deferred convenience: direct `has_*` / `find_*` wrappers are not added for now.
OCaml callers can compose the list extractors with stdlib list operations, for
example `Cause.failures cause |> List.find_opt predicate`. Add named wrappers
only if real call sites show repeated boilerplate. The typed-error-class
taxonomy (`NoSuchElementError`, `TimeoutError`, etc.) remains out of scope
because Eta uses polymorphic variants.

### 1.6 `Effect.Console` capability — **LEAVE-TO-HUMAN**
effect-smol `Console.ts` exposes `log/info/warn/error/debug/group/table/time`
etc. as effects. This is more of an application convenience than a runtime
invariant. Eta's stance ("applications own state") suggests plain stdout writes
in `Effect.sync` are fine and a full Console service is scope creep. Flag for a
human; I lean OUT-OF-SCOPE except for the parts already covered by logging.

### 1.7 Histogram / summary metric kind — **ADOPTED**
effect-smol `Metric.ts`: `counter`, `gauge`, `frequency`, `histogram`, `summary`,
`timer`.

Eta's metric surface now supports counter, gauge, frequency, histogram,
summary, and timer observations. Histograms carry explicit bucket boundaries and
aggregate count/sum/min/max/bucket counts. Summaries carry quantile/window
configuration and aggregate quantiles/count/sum/min/max. Frequencies count
string/category occurrences. `Effect.metric_timer` is real sugar over runtime
timing plus histogram observation. `Eta_otel` aggregates the richer states,
encodes them to OTLP JSON, and the terminal exporter renders the same structured
metric points.

### 1.8 Level-named log helpers (`log_info` / `log_error` / …) — **ADOPTED**
effect-smol: `Effect.logTrace`/`logDebug`/`logInfo`/`logWarning`/`logError`/
`logFatal` (plus `logWithLevel`). Eta now exposes `Effect.log_trace`,
`log_debug`, `log_info`, `log_warn`, `log_error`, and `log_fatal` as direct
sugar over `Effect.log ?level`.

Accepted by the committed research verdict in
`/home/ribelo/projects/ribelo/ocaml/Eta-logging-api-research/logging-api-evidence/verdict.md`
V-X2.

### 1.9 Scoped runtime settings (`with_minimum_log_level`, etc.) — **CONSIDER**
effect-smol `References.ts` exposes scoped runtime knobs adjustable for a region:
`MinimumLogLevel` (`Effect.withMinimumLogLevel`), `TracerEnabled`,
`CurrentConcurrency`, `LogToStderr`, `UnhandledLogLevel`. Eta already has
`suppress_observability` (a tracer-off region) and per-call concurrency via
`for_each_par_bounded ~max`, so most of this is covered. The one clear gap is a
scoped **minimum log level** — "raise verbosity to Debug just inside this block"
or "drop everything below Warn here" — which complements the logger-level filter
(1.2) but applies dynamically per effect scope rather than per logger. CONSIDER
a `with_minimum_log_level : level -> ('a,'err) t -> ('a,'err) t`.

---

## 2. Effect combinators (small, high-frequency)

Eta's `Effect` surface is deliberately lean but now includes the high-frequency
runtime and observer combinators adopted from this catalogue. Remaining entries
below are either convenience sugar or larger protocol decisions.

### 2.1 `result` / `option` / `exit` — **ADOPTED**
effect-smol: `Effect.either`, `Effect.option`, `Effect.exit`.

Eta exposes the OCaml spelling as `Effect.result`, plus `Effect.option` and
`Effect.exit`. These materialize typed failure or full exit information into
the success channel without leaving Eta's runtime boundary. Defects,
interruption, and finalizer diagnostics remain failed causes for `result` and
`option`; `exit` captures the full `Exit.t`.

### 2.2 `ignore` — **ADOPTED**
effect-smol: `Effect.ignore` / `ignoreCause`.

Eta exposes `Effect.ignore`, which discards successful values and suppresses
typed failures while preserving defects, interruption, and finalizer
diagnostics. The older unit-specialized `ignore_errors` remains available for
best-effort unit effects.

### 2.3 `orElse` / `orElseSucceed` / `orDie` — **ADOPTED / partial**
effect-smol: `Effect.orElse`, `orElseSucceed`, `orDie`.
- `orElse : (unit -> ('a,'err2) t) -> ('a,'err1) t -> ('a,'err2) t`
- `orElseSucceed : (unit -> 'a) -> ('a,'err) t -> ('a,'never) t`
- `or_die : ('err -> exn) -> ('a,'err) t -> ('a,'outer) t` (promote typed
  failure to defect)

Eta exposes `Effect.or_else`, `or_else_succeed`, and `or_die`. The recovery
forms are intentionally thin sugar over Eta's existing `catch` boundary:
success passes through, fallbacks are lazy, and only typed failures are
recovered. Defects, interruption, and finalizer diagnostics are not caught.
Partial only in the type spelling: Eta has no bottom error type, so
`or_else_succeed` returns `('a, 'outer) t`.

### 2.4 `when` / `unless` — **ADOPTED**
effect-smol: `Effect.when` / `unless` (+ effectful predicate variants).

Eta exposes `Effect.when_`, `unless`, `when_effect`, and `unless_effect`.
They return `Some value` when the guarded effect runs and succeeds, `None` when
skipped, and preserve normal Eta failure behavior for predicate or guarded
effect failures. OCaml reserves `when`, so Eta uses `when_`.

### 2.5 `timed` — **ADOPTED**
effect-smol: `Effect.timed` → `(Duration.t * 'a)`.

Eta exposes `Effect.timed`, measured with the active runtime clock so tests and
runtime constructors can keep deterministic clock behavior.

### 2.6 `sleep` / clock access (`now` / `clockWith`) — **ADOPTED**
effect-smol: `Effect.sleep`, `Effect.clock`, `clockWith`.

Eta exposes `Effect.sleep` and `Effect.now` against the active runtime clock.
There is no separate `clockWith` service accessor; the direct `now`/`sleep`
helpers cover the small deterministic-clock slice.

### 2.7 `forever` / `iterate` / `loop` — **ADOPTED / partial**
effect-smol: `Effect.forever`, `iterate`, `loop`. Eta has `repeat` (schedule
driven).

Eta exposes `Effect.forever` as thin sugar over the repeat/schedule machinery:
successful values are discarded and the source repeats forever until typed
failure, defect, interruption, or finalizer diagnostics stop the loop normally.
`iterate` and `loop` remain deferred; they overlap with ordinary recursion and
have not earned additional surface yet.

### 2.8 `filterOrFail` — **ADOPTED**
effect-smol: `Effect.filterOrFail` (assert a predicate on the success value,
else fail with a supplied error).

Eta exposes the narrow typed-error form as `Effect.filter_or_fail`:
`filter_or_fail : ('a -> bool) -> if_false:('a -> 'err) -> ('a,'err) t ->
('a,'err) t`. It preserves the source success when the predicate is true,
fails with the `if_false` value when false, and leaves source failures and
diagnostics to propagate normally. Eta deliberately does not import Effect's
`NoSuchElementError` taxonomy.

### 2.9 Effectful / cause-aware tap observers — **ADOPTED**
effect-smol: `Effect.tapBoth`, `tapErrorCause`, `tapDefect`.

Eta now exposes effectful `tap`, effectful `tap_error` for the first typed
failure, `tap_cause` for the full cause, and `tap_defect` for the first defect.
Observer failures fail normally instead of becoming suppressed/finalizer
diagnostics. A named `tap_both` remains only convenience sugar over success and
failure observers.

### 2.10 Typed-failure selective catch (`catchTag` / `catchIf`) — **ADOPTED**
effect-smol: `Effect.catch`, `catchTag`, `catchCauseIf`. Eta's `catch` catches
all typed failures. Eta now exposes
`catch_some : ('err -> ('a, 'err) t option) -> ('a, 'err) t -> ('a, 'err) t`
for same-row selective recovery: `Some` recovers, `None` preserves the original
cause. Defects, interruption, and finalizer diagnostics are not caught.

### 2.11 `sandbox` / `unsandbox` — **CONSIDER**
effect-smol: `Effect.sandbox` (expose the full `Cause` in the error channel) /
`unsandbox`. Eta has `catch` over typed errors only and `Exit` exposes the cause
at the boundary. A `sandbox : ('a,'err) t -> ('a, 'err Cause.t) t` would let
users handle defects/interrupts inside the effect rather than only at run
boundary. Powerful but a sharp tool; verify it does not let users silently
swallow interrupts (Eta cares about interruption integrity). Human decision.

### 2.12 `retry` family: `retryN` / `retryOrElse` / `repeatN` — **PARTIAL**
effect-smol: `Effect.retryOrElse`, schedule-less `retryN`. Eta's `retry` takes a
full `Schedule.t` + an `'err -> bool` predicate, which already covers `retryN`
(via `Schedule.recurs`). `retryOrElse` (run a fallback when the schedule is
exhausted) is now exposed as `retry_or_else`; schedule-less `retryN` and
`repeatN` remain convenience candidates.

### 2.13 Error accumulation: `validate` / `validateAll` / `partition` — **CONSIDER**
effect-smol: `Effect.validate`, `validateAll`, `partition`. Eta's `all` is
fail-fast and `all_settled` returns every outcome. A `validate_all` that runs all
and **accumulates** the typed failures (instead of fail-fast) is a distinct,
useful behavior for form/config validation. Slightly bigger than a one-liner;
needs an error-collection type. Human decision on whether Eta wants accumulation
semantics or leaves it to `all_settled` + manual partition.

### 2.14 `cached` / `cached_with_ttl` / `memoize` — **ADOPTED / optional package**
effect-smol: `Effect.cached`, `cachedWithTTL`, `cachedInvalidateWithTTL`; ZIO:
`ZIO.cached(ttl)`, `ZIO.memoize`. Eta now ships the heavier keyed cache as the
optional `eta_cache` package, keeping LRU/TTL/single-flight cache dependencies
outside the root `eta` package. This adopts the cache portion as optional
surface area.

Core `Effect.cached` / `cached_with_ttl` / `memoize` helpers remain deferred.
Do not add them to `lib/eta` unless separately requested; the root package still
owns effect description and interpretation, not a general cache subsystem.

### 2.15 `timeout_fail` / `disconnect` — **mostly COVERED / niche**
ZIO: `timeoutFail` (timeout with a custom error) is already covered by Eta's
`timeout_as`. `disconnect` (detach a region from external interruption so it runs
to completion) is niche and overlaps with `uninterruptible`; flag only if a
consumer needs the precise "interrupt returns immediately, region finishes in
background" semantics. Recorded for completeness; no action recommended.

### 2.16 Selective cleanup: `on_interrupt` / `on_error` — **ADOPTED**
effect-smol/ZIO: `Effect.onInterrupt` (run cleanup **only** when interrupted),
`Effect.onError` (run cleanup **only** on failure/defect), plus `addFinalizer`
(register a scope finalizer without an acquired resource).

Eta now exposes `Effect.on_interrupt` and `Effect.on_error` as thin
exit-aware cleanup hooks. They preserve the original exit when cleanup succeeds
and use the same cleanup-failure reporting as `on_exit`. A separate
`addFinalizer` surface remains unported.

### 2.17 `yield` / `yield_now` (cooperative yield) — **ADOPTED**
effect-smol/ZIO: `Effect.yieldNow` — an explicit fairness yield point.

Eta exposes the backend-neutral spelling `Effect.yield`, delegating to the
runtime contract rather than directly calling a backend primitive.

### 2.18 Smaller combinators: `flip` / `from_option` / `zip` / `race_first` — **PARTIAL**
Verified present in effect-smol `Effect.ts`; current Eta status:
- **`flip`** — swap the success/error channels (`('a,'err) t -> ('err,'a) t`).
  Niche but handy for "retry until it errors" / treating an error as the value.
- **`from_option`** — adopted as
  `from_option : if_none:'err -> 'a option -> ('a,'err) t`.
- **`zip` / `zip_with`** — a **sequential** pair/combine. Eta has `par`
  (concurrent pair) and `seq` (unit-only sequencing) but no sequential
  `zip`/`map2`; today you write nested `bind`. Pure sugar, low value, flag.
- **`race_first`** — distinct from Eta's `race`, which is *first-success-wins*
  (per its doc). `race_first` settles on the first child to finish **whether it
  succeeds or fails**. That difference is a genuine behavioral choice worth
  exposing for "first to respond, even with an error" cases. CONSIDER
  `race_first` specifically; the rest are taste calls.

---

## 3. Schedule

Eta's `Schedule` (`recurs/forever/spaced/fixed/exponential/linear/both/either/
and_then/jittered/windowed/named` + driver) is solid. effect-smol
`Schedule.ts` has extras worth eyeing:

### 3.1 `fibonacci` backoff — **ADOPTED**
effect-smol: `Schedule.fibonacci`. Eta now exposes `Schedule.fibonacci` next to
`exponential`/`linear`.

### 3.2 `windowed` — **ADOPTED**
effect-smol: `Schedule.windowed(interval)`. Eta now exposes `Schedule.windowed`
and `Schedule.fixed` now uses clock-aware cadence semantics instead of behaving
like `spaced`.

### 3.3 Output/elapsed-aware combinators — **ADOPTED**
effect-smol: `Schedule.elapsed`, `during`/`upTo`, `collectOutputs`,
`tapOutput`/`tapInput`, `modifyDelay`, `whileOutput`/`recurUntil`. Eta now uses
a typed `('input, 'output, 'hook) Schedule.t` with stateful drivers that step
with input, runtime clock, elapsed metadata, output, and `Continue`/`Done`
decisions. Adopted behavior slice: `elapsed`, `during`, `modify_delay`,
effectful `tap_input`, effectful `tap_output`, `while_output`, and
`recur_until`. Existing constructors run on the same engine, and
`retry`/`repeat`/`retry_or_else`/`Resource.auto` pass real runtime clock
metadata plus their relevant schedule input. Schedule taps now run ordinary
Eta effects in the surrounding runtime: input taps run before the inner step
and do not advance inner state on failure; output taps run after both
`Continue` and `Done` outputs. Hook-free schedules still support direct
`Schedule.step`/`Schedule.next` inspection.

### 3.4 `cron` schedule — **LEAVE-TO-HUMAN**
effect-smol ships `Cron.ts` + `Schedule.cron`. A cron-driven schedule is a real
feature for periodic jobs, but cron parsing is a non-trivial chunk and arguably
belongs in an optional package (`eta_cron`?) rather than core, per the
install-only-what-you-use boundary. Flag for a human: useful, but where does it
live?

---

## 4. Random

Eta's `Random` (`int_in_range/float_in_range/bool/shuffle/weighted_choice/
sample`) is already richer than the effect-smol basics in some ways. Minor gaps:

### 4.1 `next` (uniform 0..1 float) and `next_int` — **CONSIDER**
effect-smol: `Random.next`, `nextInt`, `nextBoolean`, `nextRange`. Eta has
`float_in_range`/`int_in_range` (which subsume these). The only genuinely
missing piece is a documented "uniform [0,1)" convenience. Low priority.

### 4.2 Deterministic seeded effect (`Random.make` from value) — **CONSIDER**
effect-smol seeds a PRNG from a hashable value for reproducibility. Eta has
`random_of_seed`/`random_set_seed` at the capability layer. Mostly covered;
verify there is an ergonomic in-effect "use this seed for this scope" path.

---

## 5. Duration

Eta's `Duration` is broad (`zero/ms/seconds/.../add/subtract/times/divide/min/
max/clamp/between/scale/compare/humanize/pp`). Small gaps:

### 5.1 Human-readable format (`format` / `humanize`) — **ADOPTED**
effect-smol: `Duration.format` → `"2h 3m 4s"`.

Eta now exposes `Duration.humanize`, which renders compact human-readable
durations such as `"1s 1ms"` and `"2d 3h 4m"`. `Duration.pp` intentionally
remains the raw millisecond test printer. Covered by
`test/core_common/duration_schedule_common_suites.ml`.

### 5.2 Sub-millisecond precision — **LEAVE-TO-HUMAN**
effect-smol carries nanosecond precision; Eta's `to_ms` suggests millisecond
granularity. Whether Eta needs micro/nanosecond durations depends on real use
cases (high-resolution `timed`, latency histograms). Flag for a human; probably
not worth it unless a consumer demands it.

---

## 6. Concurrency primitives

Eta has `Queue`, `Channel`, `PubSub`, `Semaphore`, `Pool`, `Mutable_ref`,
`Supervisor`, and scoped fibers. Notable effect-smol primitives with no Eta
public equivalent:

### 6.1 `Deferred` (one-shot promise) — **LEAVE-TO-HUMAN (already rejected, with reopen triggers)**
effect-smol: `Deferred.ts`; ZIO: `Promise`. A write-once, await-many cell.
**Already evaluated and rejected** in `journal.md` V-CDv2: "the candidate is
viable and small, but the win is not large enough on its own. Direct
`Eio.Promise` is already idiomatic for one-shot signals." The documented reopen
trigger is: *"a future module can reopen this only if several package-level
protocols need the same typed result promise shape."* So this is not a fresh
idea — surface it to a human only if a concrete protocol cluster now needs a
typed one-shot (the scoped-sessions lab or `eta_stream` handoff could be that
trigger). Otherwise the standing guidance (V-CDv5) is: use `Eio.Promise`
directly.

### 6.2 `Latch` (open/close gate) — **OUT-OF-SCOPE (explicitly rejected)**
effect-smol: `Latch.ts`. A gate that fibers wait on until opened.
**Explicitly rejected** in `journal.md` V-CDv4: "Latch saves lines, but it mostly
renames `Eio.Condition` plus `Eio.Mutex`. It does not integrate typed failures or
resource ownership in a way direct Eio lacks. The abstraction is too small for
core." Standing guidance is to use `Eio.Condition` + `Eio.Mutex` directly.
Recorded here so we don't re-litigate; only reopen against a real protocol
cluster per V-CDv6.

### 6.3 `Queue` strategies + batch drain (sliding / dropping / `take_all`) — **ADOPTED / sliding deferred**
effect-smol/ZIO: bounded queues with `sliding` (drop oldest) and `dropping`
(drop newest) overflow strategies, plus batch consumers `takeAll` / `takeN` /
`takeBetween` and `poll`. Eta adopts the queue-owned pieces with an explicit
overflow knob:

- `Queue.overflow = Unbounded | Drop_new of { capacity : int } | Backpressure of
  { capacity : int }`.
- `Queue.create ?overflow ()` defaults to `Unbounded`; `Queue.unbounded ()`
  remains the source-compatible unbounded alias.
- `Queue.offer` reports admission as `true` or `false`, so dropping is not
  represented as a typed failure in the admission API.
- `Queue.offer_all` returns the values not admitted by policy; `[]` means the
  full input was admitted.
- `Queue.send` remains an enqueue-or-fail helper and fails with [`Dropped] if a
  drop-new queue rejects the value.
- `Queue.try_send` reports [`Full] for full backpressure queues and [`Dropped]
  for full drop-new queues.
- `Queue.take_all` and `Queue.take_batch` drain currently buffered values and
  release backpressure capacity.

Sliding/drop-old is deliberately deferred for now. The adopted API keeps the
strategy knob explicit, matching the journal guidance against hidden policy
defaults (V-CDv3).

### 6.4 `FiberSet` / `FiberMap` / `FiberHandle` — **LEAVE-TO-HUMAN**
effect-smol: collections that own forked fibers and interrupt them as a group.
Eta's structured-concurrency identity (`Supervisor.scoped` + `Scope.start`)
already owns grouped lifecycle, and the scoped-sessions lab (`OBJECTIVE.md`) is
actively deciding the ergonomics here. Defer to that lab's outcome; do not add a
parallel API.

### 6.5 `RcRef` / `RcMap` / `ScopedRef` — **LEAVE-TO-HUMAN**
effect-smol: reference-counted scoped resources / per-key resource maps. These
are real (connection pools keyed by host, etc.) but overlap with `Pool` and the
resource model. Flag for a human; likely an optional concern, possibly already
covered by `Pool`.

### 6.6 `SynchronizedRef` (effectful update) — **CONSIDER**
effect-smol: `SynchronizedRef` — `update` with an **effectful** function under a
lock. Eta's `Mutable_ref.update` takes a pure `'a -> 'a`. An effectful,
serialized update (`'a -> ('a,'err) t`) is a distinct, useful primitive (e.g.
update state by calling out to an effect). CONSIDER.

### 6.7 `SubscriptionRef` (observe state changes as a stream) — **CONSIDER**
effect-smol: `SubscriptionRef` — a `Ref` whose successive values can be consumed
as a `Stream` via `changes`. Behavior: reactive state where readers get the
current value and then every subsequent update. Eta has `Mutable_ref` (point
reads/writes, no subscription) and `Stream` (no ref bridge), so there is no
built-in "watch this state" primitive today. Genuinely useful for config
hot-reload, connection-state watching, UI-ish event loops. It owns a real
protocol (latest-value + change feed + close), so it plausibly clears H-W4.
Bigger than a one-liner; human decision on core vs. `eta_stream`.

### 6.8 `Pool.invalidate` (discard a known-bad checked-out resource) — **ADOPTED**
effect-smol/ZIO: `Pool.invalidate` — a borrower that detects a broken resource
(dead socket, poisoned connection) marks it so it is destroyed instead of
returned to the pool. Eta adopts this through checked-out lease handles:
`Pool.with_lease`, opaque `Pool.Lease.t`, `Pool.Lease.resource`, and
`Pool.Lease.invalidate`.

`with_resource` remains source-compatible and semantically unchanged. There is
no global raw-connection invalidation API. Borrowers explicitly invalidate a
lease; typed failure, defect, or interruption do not auto-invalidate. The marked
resource is closed once when the lease releases/finalizes, is not returned to
idle, frees capacity, increments `closed` on actual close, and reports
`stats.invalidated`, `eta.pool.invalidated`, and `"eta.pool.invalidated"`.

### 6.9 STM / transactional refs (`TxRef` family, ZIO `STM`/`TRef`) — **LEAVE-TO-HUMAN (likely deliberate omission; straddles small/big)**
**Confirmed:** Eta has no software-transactional-memory layer anywhere (`lib/`
has zero STM/transactional refs; the only "atomically" mentions are
`Mutable_ref.compare_and_set` / `Semaphore` docstrings). Both references ship a
full STM surface: effect-smol's `TxRef`, `TxQueue`, `TxHashMap`, `TxHashSet`,
`TxSemaphore`, `TxDeferred`, `TxSubscriptionRef`, `TxReentrantLock`,
`TxPriorityQueue`, and ZIO's `STM`/`TRef`/`TMap`/etc. STM gives composable
multi-variable atomic updates with automatic retry — a genuinely distinct
capability you cannot reconstruct from `Mutable_ref` + `Semaphore` without
rewriting the conflict/retry engine.

This is **not** a "small thing" — it's a whole subsystem — so it sits awkwardly
in this catalogue, but it is recorded because the objective asks what is present
in the references and absent in Eta, and STM is the one **big** capability that
appears in both yet has no Eta equivalent. It is plausibly a *deliberate*
omission: STM is heavy, and Eta's "applications own state" identity pushes shared
mutable coordination toward Eio primitives and the supervisor model. Flag for a
human: confirm whether STM was consciously dropped (document it) or is a real
future-feature gap. Default lean: out-of-scope for core, optional package at
most.

---

## 7. Stream operators

Eta's `Eta_stream.Stream` already covers a real core: `map`, `filter`,
`flat_map`, `flat_map_par`, `merge`, `fold`, `fold_effect`, `scan`, `take`,
`drop`, `chunk`, `batch`, `buffer`, `grouped`, `concat`, `range`, `map_effect`,
`take_until_effect`, the `from_*` constructors (`from_chunk`/`from_effect`/
`from_iterable`/`from_queue`/`from_eio_stream`/`from_file`), and `run`/
`run_collect`/`run_drain`. effect-smol `Stream.ts` is much larger; most of it is
intentionally out of scope, but a handful of **small, high-frequency element
operators** are missing and would smooth everyday use:

### 7.1 `tap` / `tap_error` (per-element side effect) — **ADOPTED**
effect-smol: `Stream.tap`, `tapError`. Run an effect for each element (or each
stream error) without changing the stream. The single most common stream
primitive that Eta lacked; Eta now exposes `Stream.tap` and `Stream.tap_error`.
Element taps preserve the original element when the observer succeeds and fail
the stream normally when the observer fails. Error taps observe typed stream
failures, preserve the original failure when the observer succeeds, and let the
observer failure win when it fails.

### 7.2 `take_while` / `drop_while` / `drop_until` — **ADOPTED**
effect-smol: `takeWhile`, `dropWhile`, `dropUntil` (+ effectful variants). Eta
now exposes value-only `Stream.take_while`, `take_while_effect`,
`drop_while`, `drop_while_effect`, `drop_until`, and `drop_until_effect`.
`take_while` emits the leading true prefix and excludes the first false value.
`drop_while` drops the leading true prefix, emits the first false value, and
then stops rechecking the predicate. `drop_until` drops through the first true
value, including that matching value, and then stops rechecking the predicate.

### 7.3 `filter_map` / `map_accum` — **PARTIAL**
effect-smol: `filterMap`; ZIO: `collect` / `collectZIO`. Eta now exposes the
OCaml-idiomatic option slice as `Stream.filter_map` and
`Stream.filter_map_effect`: `Some value` is emitted, `None` is dropped, and
effectful mapper failures fail the stream normally. `map_accum` remains
deferred as a separate stateful operator decision.

### 7.4 `zip` / `zip_with` / `zip_with_index` — **ADOPTED**
effect-smol: `zip`, `zipWith`, `zipWithIndex`; ZIO: `zip`, `zipWith`,
`zipWithIndex`. Eta now exposes lockstep `Stream.zip` and `zip_with`, ending
when either side ends and discarding the longer stream's unpaired remainder.
Either-side failure fails the zipped stream and cancels the sibling source.
Eta also exposes `Stream.zip_with_index`, starting at index 0 and failing
loudly if the OCaml `int` index would overflow. Wider variants such as
`zip_all`, `zip_latest`, and Cartesian/cross operators remain outside this
slice.

### 7.5 `changes` (dedup consecutive equal) — **ADOPTED**
effect-smol: `changes` / `changesWith` / `changesWithEffect`; ZIO:
`changes` / `changesWith` / `changesWithZIO`. Eta now exposes
`Stream.changes`, `changes_with`, and `changes_with_effect`. The first element
is always emitted; later values are compared against the previous emitted value
and suppressed when equivalent. `changes` uses OCaml structural equality, while
the custom comparators are expected to be equivalence relations.

### 7.6 Run helpers: `run_fold` / `run_for_each` / `run_count` — **ADOPTED**
effect-smol: `runForEach`, `runFold`, `runCount`, `runHead`, `mkString`. Eta has
`run`, `run_collect`, `run_drain`, and now also `run_for_each`, `run_fold`, and
`run_count`. These terminal helpers delegate to existing `Sink`/`fold_stream`
machinery, so `run_fold` and `run_count` summarize without materializing the
whole stream. `mk_string` and `run_head` remain outside the adopted narrow
slice.

### 7.7 Stream-level `retry` / `repeat` / `schedule` / `timeout` — **ADOPTED**
effect-smol: `Stream.fromSchedule`, `retry`, `repeat`, `schedule`, `timeout`;
ZIO: `ZStream.fromSchedule`, `retry`, `repeat`, `schedule`. Eta now wires its
typed `Schedule.t` into streams: `Stream.from_schedule`
emits continuing schedule outputs; `Stream.schedule` gates elements with
schedule inputs; `Stream.repeat` repeats the whole source stream; and
`Stream.retry` retries the whole source on typed stream failure while preserving
already-emitted prefixes. Schedule taps run as Eta effects and fail the stream
normally. Eta also now exposes the narrow idle-timeout slice as `Stream.timeout`:
the timeout is per next emitted value, resets after each value, and ends the
stream cleanly while cancelling the active upstream pull. Fallback variants such
as `timeout_or_else`, timeout-as-failure, and total stream lifetime timeouts
remain deferred.

### 7.8 Text streaming: `split_lines` / `decode_text` — **CONSIDER**
effect-smol: `splitLines`, `decodeText`, `encodeText`. Eta has `from_file`
(chunked bytes) but no line splitter, so line-oriented file/stdin processing
needs manual buffering. A `split_lines` operator is a common, self-contained
win for log/CSV/NDJSON consumers. CONSIDER (could live in `eta_stream`).

### 7.9 `throttle` / `debounce` / `grouped_within` — **LEAVE-TO-HUMAN**
effect-smol: `throttle`, `debounce`, `groupedWithin`, `aggregateWithin`. Time- and
rate-based stream shaping. Genuinely useful but each is policy-heavy (which clock,
burst behavior, partial-window flushing) — the same class of "policy choice"
concern that got generic PubSub rejected (V-CDv3). Flag for a human; only build
with a concrete consumer driving the policy.

---

## 8. ZIO-specific behaviors

Mostly overlapping with effect-smol, but ZIO has a few distinctive ones:

### 8.1 `acquire_release_exit` / exit-aware finalizers — **ADOPTED**
ZIO: finalizers that receive the `Exit` so cleanup can branch on
success/failure/interrupt.

Eta now exposes `Effect.acquire_use_release_exit` and
`Effect.with_resource_exit`. The release callback receives the full body
`Exit.t`, including success, typed failure, defect, interruption, and
body-scope finalizer failure. A scoped `acquire_release_exit` variant was not
added; Eta kept the exit-aware API on the lexical bracket/resource shape.

### 8.2 `FiberRef` (scoped, fiber-local state) — **LEAVE-TO-HUMAN**
ZIO: `FiberRef`; effect-smol: `Context.Reference`. Fiber-local, inherited-on-fork
state. Eta uses `Capabilities`/env-row DI for context and `annotate`/`with_context`
for span context, which covers much of the need. A general FiberRef may conflict
with "applications own state". Flag for a human.

### 8.3 `ZIO.never` / `dieMessage` — **ADOPTED**
ZIO: `ZIO.never` (block forever until interrupted), `ZIO.dieMessage` (die with a
string). Eta adds only `Effect.never` and `Effect.die_message`. `never` is an
interruptible parked fiber implemented with the backend-neutral runtime promise
path, and `die_message` is string-backed unchecked-defect sugar, not a typed
failure or new cause taxonomy.

### 8.4 Log spans / log annotations — **ADOPTED**
ZIO: `ZIO.logSpan`, `ZIO.logAnnotate`; effect-smol: `annotateLogs`,
`withLogSpan`. Eta now exposes `Effect.annotate_logs` for dynamic, fiber-local
log-record attributes. Nested scopes accumulate, and scoped attrs merge before
per-call `Effect.log ~attrs`.

Accepted by the committed research verdict in
`/home/ribelo/projects/ribelo/ocaml/Eta-logging-api-research/logging-api-evidence/verdict.md`
V-X1. `withLogSpan` remains deferred and was not adopted in this slice.

---

## 9. Deliberately OUT-OF-SCOPE (recorded so we don't re-litigate)

These exist in effect-smol but are general-purpose libraries, not effect-runtime
behavior. Eta should not absorb them into core:

- `Array`, `Chunk`, `HashMap`, `HashSet`, `MutableHashMap`, `Trie`, `Record`,
  `Tuple`, `Struct`, `Iterable`, `Number`, `BigInt`, `BigDecimal`, `Boolean`,
  `String` utility modules — OCaml stdlib / dedicated libs cover these.
- `Equal`, `Equivalence`, `Order`, `Ordering`, `Hash`, `Combiner`, `Reducer`,
  `Differ` — typeclass-style machinery foreign to Eta's design.
- `Match`, `Brand`, `Newtype`, `Optic`, `JsonPatch`, `JsonPointer`,
  `JsonSchema` — covered by `eta_schema` or out of scope.
- `DateTime`, `Cron` (as a standalone) — calendar logic; if wanted, optional
  package, not core (see 3.4).
- `Config` / `ConfigProvider` — configuration loading is an application concern;
  candidate for an optional `eta_config` package, **not** core. (Borderline —
  flag if a consumer asks.)
- `RequestResolver`/`Request` (batching/dedup data layer), `ManagedRuntime`,
  `LayerMap`, `ExecutionPlan` — heavier subsystems; if any is wanted it is an
  optional package, not core.

---

## 10. Verified already-covered (checked, no gap)

Recorded so these aren't re-investigated as "missing". Each was diffed against
the reference and found to meet or exceed it:

- **Tracer span shaping** — Eta has `named`, `named_kind`, `annotate`,
  `annotate_all`, `event`, `with_result_attrs`, `link_span`,
  `with_external_parent`, `with_context`, `current_span`, `current_context`.
  Covers effect-smol `Tracer`/`withSpan` span options.
- **Pool lifecycle** — Eta's `Pool` already has bounded sizing (`max_size`/
  `max_idle`), TTL/idle eviction (`idle_lifetime`/`max_lifetime`/
  `idle_check_interval`) via a runtime daemon, `health_check`, and checked-out
  invalidation via `Pool.with_lease` / `Pool.Lease.invalidate`. This is
  *richer* than effect-smol `Pool.makeWithTTL`.
- **Semaphore** — `make`/`try_acquire`/`acquire`/`release`/`with_permits`/
  `with_permits_or_abort`/`available`/`waiting`/`cancelled_waiters` matches
  effect-smol `Semaphore` (`withPermits`/`take`/`release`).
- **Schedule core** — `recurs`/`forever`/`spaced`/`fixed`/`exponential`/`linear`/
  `both`/`either`/`and_then`/`jittered`/`named` covers the common reference set,
  and `fibonacci`/`windowed`/elapsed-aware combinators are now adopted (§3).
- **Random** — `int_in_range`/`float_in_range`/`bool`/`shuffle`/`weighted_choice`/
  `sample` meets or exceeds effect-smol `Random` basics (§4 notes only minor
  convenience gaps).
- **`timeout_as`** — already provides ZIO `timeoutFail` (custom timeout error).
- **`for_each_par_bounded ~max`** — already provides effect-smol
  `withConcurrency` / bounded `forEach`.
- **`finally`** — already provides effect-smol/ZIO `ensuring` (always-run
  finalizer). Selective `on_interrupt`/`on_error` variants are now adopted
  (2.16).

**Repo-wide negative check status:** this catalogue was originally based on a
source grep that found no console telemetry sinks, effect-level
sleep/result/ignore/timed helpers, or stream tap/run helpers. Those findings are
now stale because the APIs were adopted. Current still-open negative checks are
called out on their individual entries.

- **Test helpers** — `eta_test` already ships `Test_clock` (`adjust`/`set_time`/
  `now_ms`/`sleeper_count`/`sleep`), `Test_random` (seeded), `Expect`
  (`expect_ok`/`expect_typed_failure`/`expect_die`/`expect_interrupt`), and
  `Async` (`fork_run`/`await`/`yield`). This matches effect-smol
  `testing/TestClock` (`adjust`/`setTime`/`withLive`); `TestConsole`
  (`logLines`/`errorLines`) is already covered by the in-memory logger +
  `Logger.dump`. No test-ergonomics gap.
- **`Redacted`** — `lib/redacted` has `make`/`value`/`label`/`pp`/`equal`/`hash`
  plus `wipe_unsafe`, matching (and slightly exceeding) effect-smol `Redacted`/
  `Redactable`; its `pp` redacts the wrapped value. No gap.

---

## Open questions for a human

1. **Logging scope (section 1).** Console sinks for logs (1.1/1.2) and the
   console span/metric exporter (1.4) are adopted. Generic logger batching
   (1.3) is deferred; batching stays inside telemetry/network exporters unless
   a concrete sink needs its own lifecycle.
2. **How much Effect-combinator sugar does Eta want?** The behavioral/runtime
   slices are adopted. The remaining small-sugar decisions are `orElse` /
   `orElseSucceed`, `when` / `unless`, `forever` / `iterate` / `loop`, and
   `filterOrFail`, plus `flip` / sequential `zip` / `race_first`.
3. **Concurrency helpers (6.7/6.9):** `SubscriptionRef` and STM remain
   design-sensitive; STM is a subsystem, not a small port.
4. **Stream text/rate shaping (7.8/7.9):** `split_lines` / `decode_text` and
   throttle/debounce/grouped-within remain separate stream design calls.
5. **Deferred/Latch (6.1/6.2):** already decided in `journal.md` (V-CDv2/V-CDv4);
   reopen only against the documented protocol-cluster triggers (V-CDv6).

---

_Status: living catalogue. Grounded in `lib/eta/*.mli`, `lib/otel/eta_otel.mli`,
`lib/stream/eta_stream.ml`, `journal.md`, `.reference/effect-smol`, and
`.reference/zio`. The adopted/non-gap entries above have been refreshed against
current source. The current still-open verified gap called out here is no STM
subsystem (6.9). Deferred/Latch were previously rejected (6.1/6.2)._
