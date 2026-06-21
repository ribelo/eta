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
- 1.1 Console logger sinks (pretty / logfmt / json) — *the motivating example*.
- 1.4 Console span + metric exporter — the telemetry half of the same example.
- 1.2 Level-filtered / leveled console logger.
- 1.5 `Cause`/`Exit` inspection helpers (`failures`/`defects`/`squash`,
  `Exit.match`/`map`/`get_or_else`) — confirmed ergonomic gap.
- 5.1 `Duration.humanize` — confirmed: `pp` only prints raw ms; feeds 1.1.
- 7.1 `Stream.tap` / `tap_error`; 7.6 `Stream.run_for_each` / `run_fold`.

**Tier 2 — small, high-frequency effect ergonomics (likely worth it):**
- 2.1 `either`/`option`/`exit`; 2.2 `ignore`; 2.5 `timed`; 2.6 `sleep`/clock now.
- 2.9 effectful / defect-aware `tap` (`tap_defect`, effectful `tap_error`).
- 2.16 selective cleanup `on_interrupt` / `on_error` (confirmed gap).
- 8.1 exit-aware finalizer (`acquire_release_exit`) (confirmed gap).
- 3.1 `Schedule.fibonacci` (adopted).

**Tier 3 — real behavior, bigger or design-sensitive (human call):**
- 1.7 histogram/summary metric kind (confirmed gap; needs OTLP encoding).
- 2.14 `cached`/`memoize` (single-flight protocol).
- 6.7 `SubscriptionRef`; 6.8 `Pool.invalidate`; 6.3 queue strategies + batch drain.
- 2.13 error-accumulating `validate_all`.

**Tier 4 — taste/sugar or niche (default: skip unless a consumer asks):**
- 1.8 level-named log helpers; 2.3 `orElse` family; 2.4 `when`/`unless`;
  2.7 `forever`/`iterate`; 2.17 `yield_now`; 2.18 `flip`/`from_option`/`zip`;
  4.x random conveniences; 5.2 sub-ms precision.

**Already decided / don't reopen without a protocol trigger:** Deferred (6.1),
Latch (6.2) — rejected in `journal.md` V-CDv2/V-CDv4.

**Notable big-but-missing (out of "small things" scope, flagged anyway):** STM /
transactional refs (6.9) — present in both references, absent in Eta; likely a
deliberate omission to confirm + document.

**Already covered (not gaps):** see §10.

---

## 1. Observability / Logging (the motivating example)

Eta today (`lib/eta/logger.mli`): only `in_memory`, `noop`, `as_capability`,
`dump`. `lib/otel/eta_otel.mli` builds tracer/logger/meter capabilities that
**export over OTLP** — there is no human-readable terminal sink for either logs
or spans. effect-smol's `Logger.ts` ships a whole family of console sinks.

### 1.1 Console logger sinks — **PORT**
effect-smol: `Logger.consolePretty`, `consoleLogFmt`, `consoleStructured`,
`consoleJson`, plus the format functions `formatSimple`, `formatLogFmt`,
`formatStructured`, `formatJson`.

Behavior to port: a logger capability that writes `Capabilities.log_record`
values to stdout/stderr in a readable format. At minimum:
- a **pretty** sink (level color/tag + timestamp + body + attrs, span/trace ids
  when present),
- a **logfmt** sink (`level=info msg="..." key=val ...`),
- a **json** sink (one JSON object per line).

This is the exact gap the user called out. The `log_record` already carries
`level`, `body`, `ts_ms`, `attrs`, `trace_id`, `span_id`, so the data is all
present — only the rendering sink is missing. Lives naturally in `lib/eta`
(no new deps) as `Logger.console_pretty` / `Logger.console_logfmt` /
`Logger.console_json`.

### 1.2 Level-filtered / leveled console — **PORT**
effect-smol: `Logger.withLeveledConsole` (route by level: errors→stderr,
warn→console.warn, etc.) and a minimum-level filter.

Behavior: a `Logger.with_min_level : level -> Capabilities.logger -> Capabilities.logger`
wrapper that drops records below a threshold, and routing of `Error`/`Fatal`
to stderr. Small, composable, no deps.

### 1.3 Batched logger wrapper — **CONSIDER**
effect-smol: `Logger.batched` (buffer records and flush on an interval/size).
Behavior: wrap a logger so writes are coalesced. Useful for the console sinks
and for network sinks. Question: Eta's OTLP exporter already owns batching at
the export layer, so the batched wrapper is mostly for the *console* sinks —
decide whether that is worth the extra surface or whether console writes can
stay unbuffered.

### 1.4 Console / stdout span + metric exporter — **PORT**
ZIO/Effect both ship a "print telemetry to terminal" debug exporter; Eta only
has OTLP. Behavior: an `Eta_otel` (or a small `eta_otel`-adjacent) consumer that
renders finished spans and metric points to the terminal instead of shipping
them over the wire. This is the span/meter analogue of 1.1 and is the second
half of the user's example ("OTL to the console"). Decide placement: a debug
tracer/meter probably belongs next to the existing OTLP exporter in `lib/otel`,
or as a tiny `Tracer`/`Meter` helper in core if it needs no deps.

### 1.5 `Cause` / `Exit` inspection + pretty rendering — **PORT (confirmed gap)**
effect-smol `Cause.ts`: `pretty`, `prettyErrors`, `squash`, `hasFails`/`findFail`,
`findError`, `hasDies`/`findDie`/`findDefect`, `hasInterrupts`/`findInterrupt`,
`interruptors`, `annotate`. `Exit.ts`: `match`, `map`, `mapError`, `mapBoth`,
`getOrElse`, `getSuccess`, `getCause`, `isSuccess`/`isFailure`, `asVoid`.

**Confirmed:** Eta's `Cause` exposes only `map`/`equal`/`pp`/`is_interrupt_only`
(plus constructors), and `Exit` exposes only `ok`/`error`/`to_result`/`equal`/
`pp`. So after a run there is no ergonomic way to:
- extract the typed **failures** / **defects** / **interruptors** out of a cause
  tree (today you must hand-walk the recursive `Cause.t`);
- **squash** a cause to a single representative error/exn;
- `match`/`map`/`get_or_else` over an `Exit.t` without manually destructuring.

`to_result` only succeeds for a single typed failure, so multi-failure /
defect / interrupt outcomes are awkward to handle. A small set of
`Cause.failures`/`defects`/`interruptors`/`squash` extractors plus
`Exit.match`/`map`/`get_or_else` are real ergonomic gaps (not sugar over a
one-liner). A batteries-included `Cause.pretty : ('err -> string) -> 'err
Cause.t -> string` (over the existing `pp`) also feeds the console logger (1.1)
and a top-level unhandled-defect reporter, rendering suppressed-finalizer trees
readably. Recommend the extractor + `Exit` combinator set; CONSIDER how much of
the typed-error-class taxonomy (`NoSuchElementError`, `TimeoutError`, etc.) Eta
wants — Eta uses polymorphic variants instead, so most of that taxonomy is
OUT-OF-SCOPE.

### 1.6 `Effect.Console` capability — **LEAVE-TO-HUMAN**
effect-smol `Console.ts` exposes `log/info/warn/error/debug/group/table/time`
etc. as effects. This is more of an application convenience than a runtime
invariant. Eta's stance ("applications own state") suggests plain stdout writes
in `Effect.sync` are fine and a full Console service is scope creep. Flag for a
human; I lean OUT-OF-SCOPE except for the parts already covered by logging.

### 1.7 Histogram / summary metric kind — **CONSIDER (confirmed gap)**
effect-smol `Metric.ts`: `counter`, `gauge`, `frequency`, `histogram`, `summary`,
`timer`. **Confirmed:** Eta's metric kinds are only `Counter_cumulative`,
`Counter_monotonic`, and `Gauge` (`lib/eta/capabilities.mli`); there is no
`histogram`/`summary`/`bucket`/`quantile` anywhere in core or `lib/otel`. That
means latency/size **distributions** cannot be recorded — a real gap for any
performance instrumentation, and the natural sink for a `timed` (2.5) result.
Larger than a one-liner (needs bucket boundaries + aggregation), and the OTLP
exporter would need histogram encoding, so it is a CONSIDER rather than a quick
PORT, but it is a genuine behavioral hole worth a human's prioritization.

### 1.8 Level-named log helpers (`log_info` / `log_error` / …) — **CONSIDER (tiny)**
effect-smol: `Effect.logTrace`/`logDebug`/`logInfo`/`logWarning`/`logError`/
`logFatal` (plus `logWithLevel`). Eta has a single `Effect.log ?level:... msg`.
The per-level helpers are pure sugar over the `?level` argument, but they read
better at call sites (`Effect.log_info "..."`) and match what users expect from
the reference. Trivial to add; human decision on whether the sugar earns six
extra names.

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

Eta's `Effect` surface is deliberately lean (`pure/fail/sync/map/bind/tap/seq/
concat/race/par/all/for_each_par*/catch/map_error/tap_error/retry/delay/timeout/
repeat/finally/acquire_*/scoped`). The following are small, very common
combinators that are currently absent. Each is sugar over existing primitives,
so the question is always "does this earn surface?" — but several are used
constantly.

### 2.1 `either` / `option` / `exit` — **PORT**
effect-smol: `Effect.either`, `Effect.option`, `Effect.exit`.
Behavior: reify the error channel into the success channel:
- `either : ('a,'err) t -> (('a,'err) result, 'never) t`
- `option : ('a,'err) t -> ('a option, 'never) t`
- `exit   : ('a,'err) t -> (('a,'err) Exit.t, 'never) t`

These are the canonical "I want to inspect the outcome without failing" tools
and are the building block for retry/validation logic. `Exit.to_result` exists
but there is no effect-level reifier. High value, tiny.

### 2.2 `ignore` — **PORT**
effect-smol: `Effect.ignore` / `ignoreCause`. Behavior: run for effect, discard
both success value and typed failure (`-> (unit, 'never) t`). Extremely common;
today users must write `catch`/`map` boilerplate.

### 2.3 `orElse` / `orElseSucceed` / `orDie` — **CONSIDER**
effect-smol: `Effect.orElse`, `orElseSucceed`, `orDie`.
- `orElse : (unit -> ('a,'err2) t) -> ('a,'err1) t -> ('a,'err2) t`
- `orElseSucceed : (unit -> 'a) -> ('a,'err) t -> ('a,'never) t`
- `or_die : ('err -> exn) -> ('a,'err) t -> ('a,'outer) t` (promote typed
  failure to defect)

`catch` can express `orElse`, so these are sugar. `orDie` is the interesting one
(turn an expected failure into an unrecoverable defect) and matches Eta's
"break loudly" rule. ADOPTED for `or_die`, CONSIDER for the others.

### 2.4 `when` / `unless` — **CONSIDER**
effect-smol: `Effect.when` / `unless` (+ effectful predicate variants).
Behavior: conditionally run an effect, returning `'a option`. Common control
flow. Tension: trivially expressible with `if ... then ... else Effect.pure`.
Worth it mainly for the `option`-wrapping ergonomics. Human decision.

### 2.5 `timed` — **PORT**
effect-smol: `Effect.timed` → `(Duration.t * 'a)`. Behavior: measure wall-clock
of an effect using the runtime clock. Eta already threads a clock through the
runtime; exposing elapsed time is a small, frequently-wanted primitive that
users otherwise hack with `Effect.sync (Unix.gettimeofday)` (which bypasses the
runtime clock and breaks the test clock). Doing it inside the runtime keeps the
deterministic-clock invariant. Recommend.

### 2.6 `sleep` / clock access (`now` / `clockWith`) — **PORT**
effect-smol: `Effect.sleep`, `Effect.clock`, `clockWith`. Eta has a `clock`
capability and `Effect.delay` (delay-then-run) but **no standalone**
`Effect.sleep : Duration.t -> (unit,'never) t` and no effect to read the current
time from the runtime clock. Users who want "sleep here" or "what time is it
(deterministically, honoring the test clock)" have no in-effect path. Small and
important for determinism. Recommend.

### 2.7 `forever` / `iterate` / `loop` — **CONSIDER**
effect-smol: `Effect.forever`, `iterate`, `loop`. Eta has `repeat` (schedule
driven). `forever` (repeat until interrupt) and `iterate`/`loop` (stateful
recursion with an effect body) are convenient but overlap with `repeat` +
recursion. Human decision on whether they earn surface.

### 2.8 `filterOrFail` — **CONSIDER**
effect-smol: `Effect.filterOrFail` (assert a predicate on the success value,
else fail with a supplied error). Common validation step. Easily written with
`bind` + `if`. CONSIDER.

### 2.9 `tap_both` / `tap_error_cause` / `tap_defect` — **CONSIDER**
effect-smol: `Effect.tapBoth`, `tapErrorCause`, `tapDefect`. Eta has
`tap` (success) and `tap_error` (typed failure, side-effecting, non-effectful
observer). Gaps:
- observe the **full cause** (including defects/interrupts), not just typed
  failures;
- observe **defects only** (great for "log unexpected crashes" without touching
  expected failures);
- an **effectful** error observer (current `tap_error` takes `'err -> unit`, not
  `'err -> (unit,_) t`).
The effectful + cause-aware observers are the genuinely useful additions; they
let logging of defects happen inside the effect system instead of out of band.
Recommend at least `tap_defect` + an effectful `tap_error`.

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

### 2.14 `cached` / `cached_with_ttl` / `memoize` — **CONSIDER**
effect-smol: `Effect.cached`, `cachedWithTTL`, `cachedInvalidateWithTTL`; ZIO:
`ZIO.cached(ttl)`, `ZIO.memoize`. Behavior: turn an effect into one whose result
is computed once (or once per TTL window) and reused by later evaluations —
`cached : ('a,'err) t -> (('a,'err) t, 'never) t`. **Confirmed:** Eta has no
memoization anywhere in core (`lib/eta`); only `Resource` mentions caching. This
is a genuinely useful behavior (expensive config load, single-flight
initialization) that is awkward to build correctly by hand (needs a lock +
one-shot cell so concurrent callers don't double-compute). The single-flight
guarantee is a real protocol, so it plausibly clears the H-W4 bar. Bigger than a
one-liner; human decision on whether it belongs in core or an optional helper.
Note: the keyed/effect-smol `Cache.ts` (full LRU/TTL keyed cache) is a heavier,
separate concern — OUT-OF-SCOPE for core, candidate for an optional package.

### 2.15 `timeout_fail` / `disconnect` — **mostly COVERED / niche**
ZIO: `timeoutFail` (timeout with a custom error) is already covered by Eta's
`timeout_as`. `disconnect` (detach a region from external interruption so it runs
to completion) is niche and overlaps with `uninterruptible`; flag only if a
consumer needs the precise "interrupt returns immediately, region finishes in
background" semantics. Recorded for completeness; no action recommended.

### 2.16 Selective cleanup: `on_interrupt` / `on_error` — **CONSIDER (confirmed gap)**
effect-smol/ZIO: `Effect.onInterrupt` (run cleanup **only** when interrupted),
`Effect.onError` (run cleanup **only** on failure/defect), plus `addFinalizer`
(register a scope finalizer without an acquired resource). **Confirmed:** Eta has
`finally` (runs on every outcome) and `tap_error` (non-effectful,
typed-failure-only observer), but **no** interruption-only or failure-only
cleanup hook. "Release this lease only if we were cancelled" / "emit a metric
only on crash" are real patterns that today require manual `Exit`/`Cause`
inspection at the run boundary. This is the targeted cousin of the exit-aware
finalizer (8.1) and could share one implementation. Recommend considering
alongside 8.1.

### 2.17 `yield_now` (cooperative yield) — **LEAVE-TO-HUMAN**
effect-smol/ZIO: `Effect.yieldNow` — an explicit fairness yield point. Eta exposes
`supervisor_yield` **inside** a supervisor scope but no top-level
`Effect.yield_now`. Eio already yields on most blocking ops, so this is mostly
needed for tight CPU loops that never reach a suspension point. Niche; flag for a
human.

### 2.18 Smaller combinators: `flip` / `from_option` / `zip` / `race_first` — **CONSIDER (mostly tiny)**
Verified present in effect-smol `Effect.ts`, absent in Eta's `effect.mli`:
- **`flip`** — swap the success/error channels (`('a,'err) t -> ('err,'a) t`).
  Niche but handy for "retry until it errors" / treating an error as the value.
- **`from_option`** — the option analogue of Eta's existing `from_result`:
  `from_option : 'err -> 'a option -> ('a,'err) t` (None becomes a typed
  failure). Tiny, removes a common `match ... with None -> fail` boilerplate.
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
and_then/jittered/named` + driver) is solid. effect-smol `Schedule.ts` has
extras worth eyeing:

### 3.1 `fibonacci` backoff — **ADOPTED**
effect-smol: `Schedule.fibonacci`. Eta now exposes `Schedule.fibonacci` next to
`exponential`/`linear`.

### 3.2 `windowed` — **CONSIDER**
effect-smol: `Schedule.windowed(interval)` — recur on fixed wall-clock windows
(distinct from `fixed`, which is about spacing from the start). Useful for
"once per minute boundary" semantics. CONSIDER.

### 3.3 Output/elapsed-aware combinators — **CONSIDER**
effect-smol: `Schedule.elapsed`, `during`/`upTo`, `collectOutputs`,
`tapOutput`/`tapInput`, `modifyDelay`, `whileOutput`/`recurUntil`. Eta's driver
exposes `next`/`next_delay` but no "stop after total elapsed N" or
"collect outputs" combinator. `during`/`maxElapsed` (cap total retry time) is the
most practically requested. CONSIDER `until_elapsed` / `during`.

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
max/clamp/between/scale/compare/pp`). Small gaps:

### 5.1 Human-readable format (`format` / `humanize`) — **PORT (confirmed gap)**
effect-smol: `Duration.format` → `"2h 3m 4s"`. **Confirmed:** Eta's `Duration.pp`
is literally `Format.fprintf ppf "%dms" t.ms` — it only ever prints a raw
millisecond count (e.g. `"7384000ms"`), never a humanized string. A
`Duration.humanize`/`format` helper that renders `"2h 3m 4s"` is a real,
low-cost win and directly supports the console logger (1.1). Recommend.

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

### 6.3 `Queue` strategies + batch drain (sliding / dropping / `take_all`) — **CONSIDER (confirmed gap)**
effect-smol/ZIO: bounded queues with `sliding` (drop oldest) and `dropping`
(drop newest) overflow strategies, plus batch consumers `takeAll` / `takeN` /
`takeBetween` and `poll`. **Confirmed:** Eta's public `Queue` has `send`/`recv`/
`try_send`/`try_recv`/`close`/`stats` only — no overflow strategy knob and no
batch drain. The `mailbox_internal` in `lib/stream` already implements `dropped`
accounting and `take_batch`, so both behaviors exist internally; promoting (a) a
sliding/dropping strategy and (b) a `take_all`/`take_batch` drain to the public
`Queue`/`Channel` would close a real backpressure + throughput gap for batching
consumers. CONSIDER — note the journal rejected a *generic* PubSub on
policy-choice grounds (V-CDv3), so frame any strategy knob as an explicit,
named choice rather than a hidden default.

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

### 6.8 `Pool.invalidate` (discard a known-bad checked-out resource) — **CONSIDER (confirmed gap)**
effect-smol/ZIO: `Pool.invalidate` — a borrower that detects a broken resource
(dead socket, poisoned connection) marks it so it is destroyed instead of
returned to the pool. **Confirmed:** Eta's `Pool` is otherwise *richer* than the
reference (it already has `max_idle`, `idle_lifetime`, `max_lifetime`,
`idle_check_interval` eviction and a `health_check` daemon), but `with_resource`
always returns the resource to the pool and there is no per-borrow invalidate.
A broken connection therefore lingers until the health-check daemon catches it.
Adding `invalidate` (or a `with_resource` variant whose body can signal
"destroy, don't reuse") closes a real connection-pool correctness gap. CONSIDER.

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

### 7.1 `tap` / `tap_error` (per-element side effect) — **PORT**
effect-smol: `Stream.tap`, `tapError`. Run an effect for each element (or each
stream error) without changing the stream. The single most common stream
primitive that Eta lacks; today users must `map_effect (fun x -> e >>= fun () ->
pure x)`. Tiny, obviously useful.

### 7.2 `take_while` / `drop_while` / `drop_until` — **CONSIDER**
effect-smol: `takeWhile`, `dropWhile`, `dropUntil` (+ effectful variants). Eta has
`take_until_effect` and positional `take`/`drop` but no predicate-based
prefix/suffix trimming. Common; low cost.

### 7.3 `filter_map` / `map_accum` — **CONSIDER**
effect-smol: `filterMap` (map + drop `None`), `mapAccum` (stateful map carrying
an accumulator). Both are frequently reached for and awkward to express with the
current surface. `filter_map` especially.

### 7.4 `zip` / `zip_with` / `zip_with_index` — **CONSIDER**
effect-smol: `zip`, `zipWith`, `zipWithIndex`. Pairwise combine two streams or
tag elements with their index. `zip_with_index` is the cheap, common one.

### 7.5 `changes` (dedup consecutive equal) — **CONSIDER**
effect-smol: `changes` / `changesWith`. Emit an element only when it differs from
the previous one. Small and handy for state/event streams.

### 7.6 Run helpers: `run_fold` / `run_for_each` / `run_count` / `mk_string` — **PORT**
effect-smol: `runForEach`, `runFold`, `runCount`, `runHead`, `mkString`. Eta has
`run`, `run_collect`, `run_drain`. `run_for_each` (run an effect per element and
drain) and `run_fold` (fold into a summary without materializing a list) are the
two missing terminal operators people reach for constantly; `run_collect` forces
a full list today. Recommend at least `run_for_each` + `run_fold`.

### 7.7 Stream-level `retry` / `repeat` / `schedule` / `timeout` — **CONSIDER**
effect-smol: `Stream.retry`, `repeat`, `schedule`, `timeout`. Apply a `Schedule.t`
to an entire stream (retry the source on failure, repeat it, throttle emission).
Eta already has `Schedule.t`; wiring it into streams is a natural reuse but a
larger change. Human decision.

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

### 8.1 `acquire_release_exit` / exit-aware finalizers — **PORT (confirmed gap)**
ZIO: finalizers that receive the `Exit` so cleanup can branch on
success/failure/interrupt. **Confirmed:** both Eta finalizer entry points take
`release : 'a -> (unit, 'release_err) t` — the release effect gets the acquired
resource but **not** the outcome, so cleanup cannot distinguish commit-on-success
from rollback-on-failure/interrupt. effect-smol/ZIO pass the `Exit`/`Cause` to the
finalizer for exactly this. Eta already has the `Exit`/`Cause` machinery at the
release point internally, so adding an exit-aware variant
(`release : 'a -> ('b, 'err) Exit.t -> (unit, _) t`) is a real behavioral gap,
not sugar, and fits the cause/exit design. Recommend.

### 8.2 `FiberRef` (scoped, fiber-local state) — **LEAVE-TO-HUMAN**
ZIO: `FiberRef`; effect-smol: `Context.Reference`. Fiber-local, inherited-on-fork
state. Eta uses `Capabilities`/env-row DI for context and `annotate`/`with_context`
for span context, which covers much of the need. A general FiberRef may conflict
with "applications own state". Flag for a human.

### 8.3 `ZIO.never` / `dieMessage` — **PORT (tiny)**
ZIO: `ZIO.never` (block forever until interrupted), `ZIO.dieMessage` (die with a
string). `never` is occasionally needed for "park this fiber" patterns;
`die_message : string -> ('a,_) t` is a one-liner over `Cause.die`. Tiny, low
risk. Recommend the pair if a use case appears.

### 8.4 Log spans / log annotations — **CONSIDER**
ZIO: `ZIO.logSpan`, `ZIO.logAnnotate`; effect-smol: `annotateLogs`,
`withLogSpan`. Eta has span `annotate`/`annotate_all` for the **tracer**, but no
equivalent for attaching key/values to **log records** for a dynamic scope.
Since the console logger (section 1) will render `attrs`, a
`Effect.annotate_logs` that injects attrs into every `Effect.log` in scope is a
natural companion. CONSIDER alongside section 1.

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
- `Cache` (full keyed LRU/TTL cache), `RequestResolver`/`Request` (batching/
  dedup data layer), `ManagedRuntime`, `LayerMap`, `ExecutionPlan` — heavier
  subsystems; if any is wanted it is an optional package, not core. (The
  single-effect `cached`/`memoize` in 2.14 is the small, separable part.)

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
  `idle_check_interval`) via a runtime daemon, and `health_check`. This is
  *richer* than effect-smol `Pool.makeWithTTL`. Only `invalidate` is missing
  (6.8).
- **Semaphore** — `make`/`try_acquire`/`acquire`/`release`/`with_permits`/
  `with_permits_or_abort`/`available`/`waiting`/`cancelled_waiters` matches
  effect-smol `Semaphore` (`withPermits`/`take`/`release`).
- **Schedule core** — `recurs`/`forever`/`spaced`/`fixed`/`exponential`/`linear`/
  `both`/`either`/`and_then`/`jittered`/`named` covers the common reference set;
  only `fibonacci`/`windowed`/elapsed-aware combinators are gaps (§3).
- **Random** — `int_in_range`/`float_in_range`/`bool`/`shuffle`/`weighted_choice`/
  `sample` meets or exceeds effect-smol `Random` basics (§4 notes only minor
  convenience gaps).
- **`timeout_as`** — already provides ZIO `timeoutFail` (custom timeout error).
- **`for_each_par_bounded ~max`** — already provides effect-smol
  `withConcurrency` / bounded `forEach`.
- **`finally`** — already provides effect-smol/ZIO `ensuring` (always-run
  finalizer); only the *selective* `on_interrupt`/`on_error` variants are gaps
  (2.16).

**Repo-wide negative check (not just core `.mli`):** grepped all of `lib/`
(`*.ml`/`*.mli`, excluding `_build`) and confirmed there is **no** existing
console/stdout log or span sink (the only `console.log` hit is JS test output
in `eta_js_test.ml`; cause.ml hits are span-name formatting), and **no**
effect-level `sleep`/`ignore`/`either`/`timed` or stream `tap` (the `sleep`
binding in `runtime_core.ml` is an internal contract param; `either` in
`schedule.ml` is the schedule combinator). The Tier-1/Tier-2 "confirmed gap"
claims are therefore real, not just absent from the core interface.

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
   console span/metric exporter (1.4) are the clearest, highest-value ports and
   directly answer the original prompt. Confirm placement: log sinks in
   `lib/eta` (no deps), telemetry console exporter next to OTLP in `lib/otel`.
2. **How much Effect-combinator sugar does Eta want?** `either`/`option`/`exit`/
   `ignore`/`timed`/`sleep` (2.1, 2.2, 2.5, 2.6) feel clearly worth it. The rest
   (`when`/`unless`, `filterOrFail`, `orElse` family) are taste calls.
3. **Exit-aware finalizers (8.1)** and **effectful tap/observer (2.9)** are the
   two behavioral gaps (not sugar) most aligned with Eta's cause/exit design.
4. **Deferred/Latch (6.1/6.2):** already decided in `journal.md` (V-CDv2/V-CDv4);
   reopen only against the documented protocol-cluster triggers (V-CDv6).
5. **Stream papercuts (7.1/7.6):** `Stream.tap` and `run_for_each`/`run_fold`
   are the clearest small wins in the stream surface.
6. **Distribution metrics (1.7):** no histogram/summary kind exists; decide
   whether latency/size distributions are worth the bucket + OTLP-encoding cost.
7. **Cause/Exit inspection (1.5):** extractor helpers + `Exit.match`/`map`/
   `get_or_else` are confirmed ergonomic gaps; low risk, recommend.
8. **Effect memoization (2.14):** `cached`/`memoize` is real and useful but
   carries a single-flight protocol — core vs. optional helper is the decision.

---

_Status: eleventh pass. Grounded in `lib/eta/*.mli`, `lib/eta/duration.ml`,
`lib/otel/eta_otel.mli`, `lib/stream/eta_stream.ml`, `lib/eta/meter.mli`,
`lib/eta/tracer.mli`, `lib/eta/cause.mli`, `lib/eta/exit.mli`, `journal.md`
(V-CD decision diary), `.reference/effect-smol/.../{Logger,Console,Effect,
Schedule,Stream,Cause,Exit,Metric,Clock}.ts`, and `.reference/zio/.../ZIO.scala`.
Verified directly against source: `Duration.pp` prints raw ms (5.1), finalizers
do not receive the exit (8.1), no histogram/summary metric kind (1.7), no
memoization in core (2.14), `Cause`/`Exit` lack extraction/match helpers (1.5),
Deferred/Latch were previously rejected (6.1/6.2). The surface is now covered
breadth-first across core, observability, schedule, random, duration,
concurrency, stream, and the ZIO-distinctive set. Fifth pass added log-level
helpers (1.8), selective cleanup (2.16), `yield_now` (2.17), and queue batch
drain (6.3). Sixth pass added scoped runtime settings (1.9), `SubscriptionRef`
(6.7), and `Pool.invalidate` (6.8) — confirming Eta's `Pool` is otherwise richer
than the reference (TTL/lifetime eviction + health-check already present).
Future passes can deepen any entry into concrete `.mli` signatures once a human
picks priorities. Seventh pass added smaller combinators (2.18: `flip`/
`from_option`/`zip`/`race_first`) and a §10 "verified already-covered" register
(Tracer span shaping, Pool lifecycle, Semaphore, Schedule core, Random,
`timeout_as`, `for_each_par_bounded`, `finally`) so confirmed non-gaps aren't
re-investigated. Eighth pass added a top-of-file TL;DR priority ranking (Tiers
1–4) so the catalogue is directly actionable. Ninth pass hardened the Tier-1/2
"confirmed gap" claims with a repo-wide negative grep (see §10) to rule out
false positives. Tenth pass swept effect-smol `testing/*` vs `eta_test` and
found no test-ergonomics gap (recorded in §10). Eleventh pass cross-checked the
full effect-smol module list: added STM/`Tx*` (6.9) as the one big-but-missing
capability present in both references, and confirmed `Redacted` is already
covered. The behavior-level reference surface is now swept end to end._
