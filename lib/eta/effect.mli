(** Lazy, runtime-interpreted effects.

    {v
      ('a, 'err) Effect.t
       ^^   ^^^
       ok   error
    v}

    - ['a] is the success value.
    - ['err] is the typed failure channel. Polymorphic variants work well:
      [[> `Http_404 | `Db_unavailable ]].

    Dependencies are ordinary OCaml values: pass records, modules, closures, or
    concrete handles into functions that construct effects. Eta does not own a
    ZIO-style environment or layer graph.

    This signature is intentionally a facade over Eta's eff algebra,
    structured concurrency, and observability hooks. Keep
    implementation-only representation details out of this file:
    if a helper is needed only by Runtime or private modules, put it behind a
    private module such as Runtime_erasure instead of widening Effect. *)

type ('a, 'err) t

type ('s, 'a, 'err) supervisor_scope

type ('a, 'err) supervisor_body = {
  run : 's. ('s, 'err) supervisor -> ('s, 'a, 'err) supervisor_scope;
}

and ('s, !'err) supervisor
and ('s, !'err, !'a) supervisor_child

val pure : 'a -> ('a, 'err) t
val fail : 'err -> ('a, 'err) t
val unit : (unit, 'err) t
val from_result : ('a, 'err) result -> ('a, 'err) t
(** Lift an already-computed OCaml [result] into Eta.

    Use this for pure validation/parsing results. *)

val from_option : if_none:'err -> 'a option -> ('a, 'err) t
(** Lift an already-computed OCaml [option] into Eta.

    [Some value] becomes [pure value]. [None] becomes [fail if_none]. Use this
    for pure lookup/extraction results that should enter Eta's typed failure
    channel. *)

val flatten_result : (('a, 'err) result, 'err) t -> ('a, 'err) t
(** Flatten an effect that succeeds with an OCaml [result].

    This is the pipe-friendly companion to {!from_result}. Use it after
    {!sync} when a synchronous leaf returns expected typed failures as
    [result]:

    {[
      Effect.sync f |> Effect.flatten_result
    ]} *)

val sync : (unit -> 'a) -> ('a, 'err) t
(** [sync f] lifts an OCaml function into an eff. Use {!Effect.named} to
    attach a span name for tracing.

    Ordinary OCaml exceptions raised by [f] are unchecked defects and surface
    as {!Cause.Die}. They are not converted into the typed error channel and
    are not caught by {!catch}. If a synchronous leaf operation has an expected
    typed failure, return an explicit [result] and use {!flatten_result} after
    this boundary.
    Runtime cancellation exceptions remain interruption. *)

val yield : (unit, 'err) t
(** Cooperatively yield the current Eta fiber to the active runtime backend.

    This is the backend-neutral spelling for an Eta blueprint that needs a
    scheduling yield. It delegates to the runtime contract rather than calling a
    backend primitive such as [Eio.Fiber.yield] from user code. *)

val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
(** Transform the success value of an effect. In application code, the mapping
    operator from {!Syntax} is usually the more readable spelling. *)

val bind : ('a -> ('b, 'err) t) -> ('a, 'err) t -> ('b, 'err) t
(** Primitive dependent sequencing.

    This is the operation behind the sequencing operator from {!Syntax}. Prefer
    syntax operators in
    user-facing workflows; use [bind] directly for combinators, generated code,
    or code where pipeline style is materially clearer. *)

val ( >>= ) : ('a, 'err) t -> ('a -> ('b, 'err) t) -> ('b, 'err) t
(** Infix spelling of {!bind}. It is kept for advanced/library code; examples
    and documentation should usually use the sequencing operator from
    {!Syntax}. *)

val tap : ('a -> ('b, 'err) t) -> ('a, 'err) t -> ('a, 'err) t
(** Run an effectful observer on success and keep the original success value.

    The observer's success value is ignored, but its typed failure, defect,
    interruption, resource lifecycle, and runtime observability still matter.
    Wrap a plain synchronous observer with {!sync}. *)

val seq : (unit, 'err) t -> (unit, 'err) t -> (unit, 'err) t
val concat : (unit, 'err) t list -> (unit, 'err) t

val race : ('a, 'err) t list -> ('a, 'err) t
(** First child to produce a value wins; the rest are cancelled.

    Losers' values are discarded by design. Resource lifetime is owned by
    scopes, not by race: a loser that holds its resource under
    {!acquire_release} / {!Semaphore.with_permits} has it released when it is
    cancelled, even if it ran to completion before losing. An acquisition whose
    ownership is carried through a value can be discarded by race; use
    {!Semaphore.with_permits_or_abort} when racing permit acquisition against an
    abort signal. *)

val par : ('a, 'err) t -> ('b, 'err) t -> ('a * 'b, 'err) t
(** Run two effects concurrently; collect both successes as a pair.
    Fail-fast: the first child failure cancels the sibling and the
    cause propagates upward.

    This is eff concurrency on the current runtime substrate, not CPU
    parallelism. Use the optional [eta_par] package for worker-domain offload
    or explicit fork-join parallel algorithms. *)

val all : ('a, 'err) t list -> ('a list, 'err) t
(** Run effects concurrently, collecting results in input order.
    Fail-fast: the first child failure cancels the others; the cause
    of the first observed failure propagates. *)

val all_settled :
  ('a, 'err) t list -> (('a, 'err Cause.t) result list, 'outer_err) t
(** Run effects concurrently and collect every child outcome in input order.
    Child failures are returned as [Error cause] values instead of failing the
    outer eff. *)

val for_each_par : 'x list -> ('x -> ('a, 'err) t) -> ('a list, 'err) t
(** Map over [xs] concurrently with [f]; collect results in input order.
    Fail-fast like {!all}.

    This runs child effects as concurrent fibers on the current runtime
    substrate. It does not move arbitrary effects to worker domains; use the
    optional [eta_par] package for CPU-bound batch work. *)

val for_each_par_bounded :
  max:int -> 'x list -> ('x -> ('a, 'err) t) -> ('a list, 'err) t
(** Map over [xs] with at most [max] child effects running at once. Results
    are returned in input order and failures are fail-fast like {!for_each_par}.
    The bound limits concurrent fibers, not domain workers.
    @raise Invalid_argument if [max <= 0]. *)

val uninterruptible : ('a, 'err) t -> ('a, 'err) t
(** Defer parent cancellation while running the wrapped eff.

    This maps to backend cancellation protection. It does not turn
    interruption into a typed failure, and it does not catch defects. *)

val catch :
  ('err1 -> ('a, 'err2) t) -> ('a, 'err1) t -> ('a, 'err2) t
(** Handle typed failures in an eff's cause tree.

    [catch handler eff] does not catch unchecked defects, interruption, or
    cleanup/finalizer failures. This matches the ordinary typed-error recovery
    shape in ZIO [catchAll]/[foldZIO] and eff-ts [catch]/[findError]: one
    recovery decision is made from the cause, rather than traversing every
    [Fail] leaf and running one handler per branch.

    If any uncatchable defect, interruption, or finalizer diagnostic remains in
    the cause tree, the handler is not invoked and the eff stays failed with
    those uncatchable diagnostics. This avoids running recovery side effects for
    an operation that still fails, and avoids preserving old typed [Fail]
    payloads after [catch] changes the error type.

    If only typed failures remain, [catch] invokes the handler once with the
    first typed failure in cause order. Other concurrent/sequential typed
    failures are not recoverable values; use [all_settled] or explicit result
    values when every branch outcome matters. Recover or ignore cleanup failure
    inside the cleanup eff itself. *)

val catch_some :
  ('err -> ('a, 'err) t option) -> ('a, 'err) t -> ('a, 'err) t
(** Selectively handle a typed failure without changing the error row.

    [catch_some handler eff] has the same catchability boundary as {!catch}:
    it only considers failed exits whose cause tree contains recoverable typed
    failures and no defects, interruption, or finalizer diagnostics.

    When only typed failures remain, [catch_some] inspects the first typed
    failure in cause order. [Some recovery] runs that recovery effect. [None]
    preserves the original cause exactly, including composite typed failures,
    rather than rebuilding a single [Cause.Fail]. *)

val recover : ('err1 -> 'a) -> ('a, 'err1) t -> ('a, 'err2) t
(** Pure typed-failure recovery.

    [recover f eff] is shorthand for [catch (fun err -> pure (f err)) eff].
    Use {!catch} when recovery itself is effectful. Defects, interruption, and
    finalizer diagnostics are not recovered, matching {!catch}. If [f] raises,
    the exception is an unchecked defect. *)

val or_else : (unit -> ('a, 'err2) t) -> ('a, 'err1) t -> ('a, 'err2) t
(** Recover from any typed failure with a lazy fallback effect.

    [or_else fallback eff] is shorthand for [catch (fun _ -> fallback ()) eff].
    Successful values pass through without evaluating [fallback]. The fallback
    runs only for catchable typed failures. Defects, interruption, and
    finalizer diagnostics are not caught, matching {!catch}. *)

val or_else_succeed : (unit -> 'a) -> ('a, 'err) t -> ('a, 'outer) t
(** Recover from any typed failure with a lazy pure value.

    [or_else_succeed fallback eff] is shorthand for
    [catch (fun _ -> pure (fallback ())) eff]. Successful values pass through
    without evaluating [fallback]. The fallback runs only for catchable typed
    failures. Defects, interruption, and finalizer diagnostics are not caught,
    matching {!catch}. If [fallback] raises, the exception is an unchecked
    defect. *)

val when_ : bool -> ('a, 'err) t -> ('a option, 'err) t
(** Conditionally run an effect.

    [when_ condition eff] runs [eff] when [condition] is [true] and maps its
    success to [Some value]. When [condition] is [false], [eff] is not
    evaluated and the result is [None]. Typed failures, defects,
    interruption, and finalizer diagnostics from [eff] propagate normally when
    the effect runs. *)

val unless : bool -> ('a, 'err) t -> ('a option, 'err) t
(** Conditionally run an effect when a condition is false.

    [unless condition eff] is [when_ (not condition) eff]. *)

val when_effect : (bool, 'err) t -> ('a, 'err) t -> ('a option, 'err) t
(** Conditionally run an effect after evaluating an effectful predicate.

    [when_effect condition eff] evaluates [condition] first. If it succeeds
    with [true], [eff] runs and its success is returned as [Some value]. If it
    succeeds with [false], [eff] is not evaluated and the result is [None].
    Predicate failures and diagnostics fail normally; source failures and
    diagnostics fail normally when [eff] runs. *)

val unless_effect : (bool, 'err) t -> ('a, 'err) t -> ('a option, 'err) t
(** Conditionally run an effect after an effectful predicate succeeds with
    [false].

    [unless_effect condition eff] evaluates [condition] first, then behaves as
    {!unless}. Predicate failures and diagnostics fail normally. *)

val filter_or_fail :
  ('a -> bool) -> if_false:('a -> 'err) -> ('a, 'err) t -> ('a, 'err) t
(** Assert a predicate on a successful value.

    [filter_or_fail predicate ~if_false eff] preserves [eff]'s success value
    when [predicate value] is [true]. When [predicate value] is [false], it
    fails with [if_false value] in Eta's typed error channel. Source typed
    failures, defects, interruption, and finalizer diagnostics propagate
    normally. If [predicate] or [if_false] raises, the exception is an
    unchecked defect. *)

val ignore_errors : (unit, 'err1) t -> (unit, 'err2) t
(** Suppress typed failures from a best-effort unit effect.

    [ignore_errors eff] is shorthand for [catch (fun _ -> unit) eff]. It only
    recovers typed failures; defects, interruption, and finalizer diagnostics
    remain visible. Use it for best-effort cleanup, refresh, or notification
    effects whose success value is already [unit]. *)

val ignore : ('a, 'err1) t -> (unit, 'err2) t
(** Run an effect for its effects, discard a successful value, and suppress
    typed failures.

    [ignore eff] succeeds with [()] when [eff] succeeds or fails only with
    typed failures. Defects, interruption, and finalizer diagnostics remain
    visible. Use {!ignore_errors} for the older unit-specialized spelling. *)

val result : ('a, 'err1) t -> (('a, 'err1) result, 'err2) t
(** Materialize the typed failure channel into an ordinary OCaml [result].

    [result eff] succeeds with [Ok value] when [eff] succeeds and with
    [Error err] when [eff] fails with a typed failure. Defects, interruption,
    and finalizer diagnostics are not captured; they remain failed Eta causes.
    Use this when a workflow should keep going and handle success/failure as
    data without leaving Eta's runtime boundary. *)

val option : ('a, 'err1) t -> ('a option, 'err2) t
(** Materialize success as [Some value] and typed failure as [None].

    [option] discards typed failure payloads. Defects, interruption, and
    finalizer diagnostics are not captured; they remain failed Eta causes.
    Use {!result} when the typed failure value matters. *)

val exit : ('a, 'err1) t -> (('a, 'err1) Exit.t, 'err2) t
(** Materialize the full Eta exit as a success value.

    [exit eff] succeeds with [Exit.Ok value] when [eff] succeeds and with
    [Exit.Error cause] when [eff] fails with a typed failure, defect,
    interruption, or finalizer diagnostic. *)

val map_error : ('err1 -> 'err2) -> ('a, 'err1) t -> ('a, 'err2) t
(** Transform typed failures while preserving unchecked defects, interruption,
    and the surrounding cause structure. [Cause.Fail] values in the primary
    cause tree are mapped, including failures nested under [Sequential] and
    [Concurrent]. Cleanup/finalizer failures are already rendered into
    {!Cause.Finalizer} nodes and are preserved unchanged, including
    [Cause.Suppressed.finalizer] branches. *)

val or_die : ('err -> exn) -> ('a, 'err) t -> ('a, 'outer) t
(** Convert typed failures into unchecked defects.

    [or_die to_exn eff] preserves successful values. On failure, every
    [Cause.Fail err] in the primary cause tree becomes a [Cause.Die] built from
    [to_exn err]. [Sequential] and [Concurrent] structure is preserved.
    Existing defects, interruption, and finalizer diagnostics are preserved.
    For [Cause.Suppressed], only the primary cause is converted; the rendered
    finalizer diagnostic is left unchanged.

    If [to_exn] raises, the exception is reported through Eta's ordinary defect
    capture path. *)

val tap_error : ('err -> (unit, 'err) t) -> ('a, 'err) t -> ('a, 'err) t
(** Run an effectful observer on the first typed failure, then preserve the
    original failure when the observer succeeds.

    [tap_error] does not observe defects or interruption-only causes. If the
    observer fails, its failure becomes the result normally, as in ordinary
    sequencing; it is not reported as a finalizer or suppressed diagnostic. *)

val tap_cause :
  ('err Cause.t -> (unit, 'err) t) -> ('a, 'err) t -> ('a, 'err) t
(** Run an effectful observer with the full cause of any failed exit, then
    preserve the original failure when the observer succeeds. Observer failure
    fails normally from the observer path. *)

val tap_defect :
  (Cause.die -> (unit, 'err) t) -> ('a, 'err) t -> ('a, 'err) t
(** Run an effectful observer on the first defect in the cause tree, then
    preserve the original failure when the observer succeeds. Observer failure
    fails normally from the observer path. *)

val retry :
  ('err, 'schedule_out, (unit, 'err) t) Schedule.t ->
  ('err -> bool) ->
  ('a, 'err) t ->
  ('a, 'err) t
(** Retry an effect while the schedule continues and [predicate] accepts the
    typed failure. The typed failure is passed to the schedule as input.
    Schedule taps run in the current Eta runtime; tap failures fail the retry
    normally through the same typed channel. Defects, interruption, and
    finalizer diagnostics are not retried. *)

val retry_or_else :
  ('err1, 'schedule_out, (unit, 'err2) t) Schedule.t ->
  ('err1 -> bool) ->
  or_else:('err1 -> 'schedule_out option -> ('a, 'err2) t) ->
  ('a, 'err1) t ->
  ('a, 'err2) t
(** Retry an effect while the schedule continues and [predicate] accepts the
    typed failure, then run [or_else] with the final typed failure when the
    predicate rejects it or the schedule is exhausted.

    The typed failure is passed to the schedule as input. [or_else] receives
    the latest schedule output when at least one schedule step has run,
    including the terminal [Done] output when the schedule is exhausted. It
    receives [None] when [predicate] rejects the first typed failure before any
    schedule step. For composite causes, [retry_or_else] follows {!catch}: it
    handles only causes whose primary tree contains typed failures and no
    uncatchable defects, interruption, or finalizer diagnostics, and it uses the
    first typed failure in cause order. Uncatchable diagnostics are not retried
    and do not run [or_else].

    Schedule taps run in the current Eta runtime. Tap failures and [or_else]
    failures become the result normally; the original typed failure is not
    suppressed or reported as a finalizer diagnostic. *)

val now : (int, 'err) t
(** Read the active runtime clock in milliseconds. Runtime constructors and
    tests can override this clock with their [?now_ms] argument. *)

val sleep : Duration.t -> (unit, 'err) t
(** Sleep through the active runtime clock. Runtime constructors and tests can
    override this sleeper with their [?sleep] argument. *)

val delay : Duration.t -> ('a, 'err) t -> ('a, 'err) t
val timed : ('a, 'err) t -> (Duration.t * 'a, 'err) t
(** Measure an effect with the active runtime clock.

    On success, [timed eff] returns [(elapsed, value)]. Typed failures,
    defects, interruption, and finalizer diagnostics are preserved as the
    original failed outcome. *)

val timeout : Duration.t -> ('a, [> `Timeout ] as 'err) t -> ('a, 'err) t
val timeout_as :
  Duration.t -> on_timeout:'err -> ('a, 'err) t -> ('a, 'err) t
(** Like {!timeout}, but fails with [on_timeout] instead of widening the error
    row with raw Timeout. *)
val repeat :
  ('a, 'output, (unit, 'err) t) Schedule.t ->
  ('a, 'err) t ->
  ('output, 'err) t
(** Repeat a successful effect according to [schedule].

    The source effect is evaluated once before the schedule is stepped. Each
    successful value is passed to the schedule as input. When the schedule
    continues, Eta sleeps for the step delay and runs the source again. When the
    schedule is done, [repeat] succeeds with the schedule output. Schedule taps
    run in the current Eta runtime; tap failures fail [repeat] normally through
    the same typed channel. The first source failure stops the loop. *)

val forever : ('a, 'err) t -> ('b, 'err) t
(** Repeat an effect forever, discarding every successful value.

    [forever eff] runs [eff], discards a successful value, and immediately
    repeats after every success. The returned effect never succeeds. A typed
    failure, defect, interruption, or finalizer diagnostic from [eff] stops the
    loop and propagates normally. *)

val finally : (unit, 'cleanup_err) t -> ('a, 'err) t -> ('a, 'err) t
(** [finally cleanup eff] runs [cleanup] after [eff] settles, on success,
    typed failure, unchecked defect, or cancellation.

    [cleanup] runs in a cancellation-protected cleanup frame. If [eff]
    succeeds but [cleanup] fails, the cleanup failure is reported as
    [Cause.Finalizer]. If both fail, the cleanup failure is reported as a
    suppressed finalizer failure under the primary cause, matching
    {!acquire_release} finalizer reporting.

    This is for one-shot cleanup around an eff. Use {!with_resource} for
    body-bounded resource lifetimes, or {!acquire_release} and {!scoped} when
    the resource should live until an enclosing runtime or scope boundary. *)

val on_exit :
  (('a, 'err) Exit.t -> (unit, 'cleanup_err) t) ->
  ('a, 'err) t ->
  ('a, 'err) t
(** [on_exit cleanup eff] runs [cleanup] with the full exit of [eff].

    On success, [cleanup] receives [Exit.Ok value]. On typed failure,
    unchecked defect, or interruption, it receives [Exit.Error cause].
    Cleanup failures are reported with the same finalizer/suppressed-finalizer
    rules as {!finally}; the original result is preserved when cleanup
    succeeds. *)

val on_error :
  ('err Cause.t -> (unit, 'cleanup_err) t) ->
  ('a, 'err) t ->
  ('a, 'err) t
(** [on_error cleanup eff] runs [cleanup cause] only when [eff] exits with an
    error cause that is not interruption-only.

    This includes typed failures, unchecked defects, composite failures, and
    suppressed finalizer failures. The original exit is preserved when cleanup
    succeeds; cleanup failures follow the same reporting rules as {!on_exit}. *)

val on_interrupt :
  (Cause.interrupt_id option -> (unit, 'cleanup_err) t) ->
  ('a, 'err) t ->
  ('a, 'err) t
(** [on_interrupt cleanup eff] runs [cleanup interrupt_id] only when [eff] exits
    with an interruption-only cause.

    If the interruption cause is composite, [interrupt_id] is the first
    interruption id found in the cause tree, or [None] when all interruptions
    are anonymous. Cleanup failure reporting matches {!on_exit}. *)

val acquire_release :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'release_err) t) ->
  ('a, 'err) t
(** Acquire a resource and register [release] to run when the current runtime
    boundary, scope, supervisor scope, or daemon body exits. The release eff
    runs on success and on typed failure; release failures are reported as
    [Cause.Finalizer] after a successful body or suppressed onto the primary
    failure after a failed body. *)

val acquire_use_release :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'release_err) t) ->
  ('a -> ('b, 'err) t) ->
  ('b, 'err) t
(** Acquire a resource, run [body], and release it when [body] finishes.

    This is a lexical bracket. Unlike {!acquire_release}, it opens a local scope
    around [body], so repeated [acquire_use_release] calls do not retain
    resources until the surrounding runtime boundary exits. Release ordering,
    cancellation protection, and suppressed finalizer failure reporting match
    scoped {!acquire_release}. *)

val acquire_use_release_exit :
  acquire:('a, 'err) t ->
  release:('a -> ('b, 'err) Exit.t -> (unit, 'release_err) t) ->
  ('a -> ('b, 'err) t) ->
  ('b, 'err) t
(** Acquire a resource, run [body], and release it with the full exit of the
    scoped body.

    This is the exit-aware lexical bracket. [release] sees [Exit.Ok value] for
    body success and [Exit.Error cause] for typed failure, defect, interruption,
    or body-scope finalizer failure. Release failures use the same finalizer and
    suppressed-finalizer reporting as {!acquire_use_release}. *)

val with_resource :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'release_err) t) ->
  ('a -> ('b, 'err) t) ->
  ('b, 'err) t
(** Friendly name for {!acquire_use_release}. This is the preferred shape for
    body-bounded resource use, especially with {!Syntax.(let@)}:

    {[
      let open Eta.Syntax in
      let@ conn = Effect.with_resource ~acquire ~release in
      body conn
    ]}

    Use {!acquire_release} directly when a resource should live until an
    enclosing runtime or {!scoped} boundary rather than just the callback body. *)

val with_resource_exit :
  acquire:('a, 'err) t ->
  release:('a -> ('b, 'err) Exit.t -> (unit, 'release_err) t) ->
  ('a -> ('b, 'err) t) ->
  ('b, 'err) t
(** Friendly name for {!acquire_use_release_exit}. *)

val scoped : ('a, 'err) t -> ('a, 'err) t
(** Open a resource scope around an effect.

    Resources registered with {!acquire_release} inside [scoped] are released
    when the scope exits, in reverse acquisition order. Finalizers run on
    success, typed failure, unchecked defect, and cancellation.

    Scopes compose: nested [scoped] blocks release their own resources before
    the outer scope continues. Use this for resource lifetimes that should not
    extend to the runtime boundary. *)

val with_background :
  ?name:string -> (unit, 'err) t -> (unit -> ('a, 'err) t) -> ('a, 'err) t
(** Run [background] while [use] executes, then cancel the background child when
    [use] returns or fails. This is the structured replacement for
    daemon-shaped application work that does not need to expose a child handle. *)

val daemon : (unit, 'err) t -> (unit, 'err) t
(** Start runtime-owned finite background work on the runtime's outer switch.

    Daemons are for Eta modules that own a lifecycle beyond the caller's local
    scope, such as pool eviction loops and protocol readers. Application code
    should prefer {!with_background} when the work belongs to one request,
    server, stream, or resource scope.

    Failures bypass the typed result and are reported as runtime daemon
    diagnostics. Use {!Runtime.drain} to wait for currently running finite
    daemon work before process shutdown or tests that assert daemon effects. *)

val supervisor_scoped :
  ?max_failures:int -> ('a, 'err) supervisor_body -> ('a, 'err) t
(** Low-level abstract supervisor-scope runner used by {!Supervisor}. Prefer
    {!Supervisor.scoped} and {!Supervisor.Scope} in user code. *)

val with_error_renderer : ('err -> string) -> ('a, 'err) t -> ('a, 'err) t
(** Render typed failures in observability span status and exception events for
    the wrapped eff. The renderer is scoped to this eff's error channel. *)

val suppress_observability : ('a, 'err) t -> ('a, 'err) t
(** Run the wrapped eff without emitting tracer, logger, or meter events
    from inside the subtree.

    This is intended for observability exporters and other observer backends
    that must call Eta-based libraries without recursively observing their own
    export path. It does not change typed errors, resource finalization, or
    defect diagnostics. *)

val supervisor_pure : 'a -> ('s, 'a, 'err) supervisor_scope
val supervisor_lift : ('a, 'err) t -> ('s, 'a, 'err) supervisor_scope
val supervisor_fail : 'err -> ('s, 'a, 'err) supervisor_scope

val supervisor_bind :
  ('a -> ('s, 'b, 'err) supervisor_scope) ->
  ('s, 'a, 'err) supervisor_scope ->
  ('s, 'b, 'err) supervisor_scope

val supervisor_start :
  ('s, 'err) supervisor ->
  ('s, 'a, 'err) supervisor_scope ->
  ('s, ('s, 'err, 'a) supervisor_child, 'outer_err) supervisor_scope

val supervisor_await :
  ('s, 'err, 'a) supervisor_child -> ('s, 'a, 'err) supervisor_scope

val supervisor_cancel :
  ('s, 'err, 'a) supervisor_child -> ('s, unit, 'err) supervisor_scope

val supervisor_failures :
  ('s, 'err) supervisor -> ('s, 'err Cause.t list, 'outer_err) supervisor_scope

val supervisor_check :
  ('s, [> `Supervisor_failed of int ] as 'err) supervisor ->
  ('s, unit, 'err) supervisor_scope

val supervisor_yield : ('s, unit, 'err) supervisor_scope
(** Low-level abstract supervisor-scope builders used by {!Supervisor.Scope}.
    They intentionally do not expose the interpreter AST constructors. *)

val named :
  ?error_renderer:('err -> string) ->
  string ->
  ('a, 'err) t ->
  ('a, 'err) t
(** [named name body] attaches a span name for tracing around [body]. *)

module Expert : sig
  type context

  val make :
    ?leaf_name:string ->
    ?names:string list ->
    (context -> ('a, 'err) Exit.t) ->
    ('a, 'err) t
  (** Build a runtime-backed effect without exposing Eta's internal effect
      representation. Runtime-specific packages use this to attach operations
      to the current {!Runtime_contract.t}; ordinary user code should prefer
      the typed combinators in this module. *)

  val contract : context -> Runtime_contract.t
  (** Runtime contract selected by the current interpreter. *)

  val current_scope : context -> Runtime_contract.scope
  (** Current lexical runtime scope. *)

  val outer_scope : context -> Runtime_contract.scope
  (** Runtime boundary scope used for runtime-owned background work. *)

  val runtime_service : context -> 'a Runtime_contract.service_key -> 'a option
  (** Runtime-package service attached when the interpreter was created. *)

  val auto_instrument : context -> bool
  (** Whether runtime leaf auto-instrumentation is enabled. *)

  val instrument_leaf : context -> name:string -> (unit -> 'a) -> 'a
  (** Run a leaf body under Eta's standard runtime instrumentation. *)

  val emit_trace_event :
    context -> name:string -> attrs:(string * string) list -> unit
  (** Emit an event on the active span, if tracing is enabled and sampled. *)

  val record_metric :
    context ->
    name:string ->
    description:string ->
    unit_:string ->
    kind:Capabilities.metric_kind ->
    attrs:(string * string) list ->
    value:Capabilities.metric_value ->
    unit
  (** Record a metric point when runtime metrics are enabled. *)

  val fork_daemon : context -> (unit -> [ `Stop_daemon ]) -> unit
  (** Fork runtime-owned finite background work and include it in
      {!Runtime.drain} accounting. *)

  val eval : context -> ('a, 'err) t -> ('a, 'err) Exit.t
  (** Evaluate a child effect in the current runtime context. *)

  val eval_in_scope :
    context -> Runtime_contract.scope -> ('a, 'err) t -> ('a, 'err) Exit.t
  (** Evaluate a child effect in an explicit runtime scope. *)

  val exit_of_exn : context -> exn -> ('a, 'err) Exit.t
  (** Convert an unchecked exception raised by a custom operation into Eta's
      diagnostic cause using the current runtime settings. *)
end
(** Narrow extension point for runtime packages. This module is intentionally
    small: it lets optional packages implement backend-specific leaves while
    keeping the root [Effect.t] representation private. *)

val named_kind :
  ?error_renderer:('err -> string) ->
  kind:Capabilities.span_kind ->
  string ->
  ('a, 'err) t ->
  ('a, 'err) t
val annotate : key:string -> value:string -> ('a, 'err) t -> ('a, 'err) t
(** Attach a string attribute to the active span. If no span is active, the
    attribute is buffered and attached to the next span opened by the same
    fiber. The same annotation is also included in defect diagnostics produced
    by the wrapped eff. *)

val annotate_all : (string * string) list -> ('a, 'err) t -> ('a, 'err) t
(** Attach several span attributes with the same semantics as {!annotate}. The
    list order is preserved. *)

val annotate_all_lazy :
  (unit -> (string * string) list) -> ('a, 'err) t -> ('a, 'err) t
(** Like {!annotate_all}, but the attribute list is only built when tracing is
    enabled in the active runtime. Use for hot paths where computing the
    attributes (e.g. formatting numbers/URLs per request) is wasted when no
    tracer is installed. When tracing is disabled the thunk is never called. *)

val is_tracing_enabled : (bool, 'err) t
(** Resolves to whether a tracer is installed in the active runtime. Use to skip
    building span wrappers on hot paths when no tracer will record them. *)

val event : ?attrs:(string * string) list -> string -> (unit, 'err) t
(** Add an event to the currently active span. If tracing is disabled or no span
    is active, this is a no-op. Use this for structured progress markers inside
    a span; use {!log} for log records and {!metric_update} for metrics. *)

val with_result_attrs :
  ok_attrs:('a -> (string * string) list) ->
  err_attrs:('err -> (string * string) list) ->
  ('a, 'err) t ->
  ('a, 'err) t
(** Attach attributes derived from the eff outcome to the active span and
    preserve the original result.

    [ok_attrs] is evaluated after success. [err_attrs] is evaluated for every
    typed [Cause.Fail] in the failure cause. Defects and interruption are not
    passed to [err_attrs].

    The attributes are recorded only when a span is active at the point the
    wrapped eff settles. Put this combinator inside {!named} or {!fn} when
    the attributes should land on that span:

    {[
      Effect.named "load.rows"
        (Effect.with_result_attrs
           ~ok_attrs:(fun rows -> [ ("row_count", string_of_int (List.length rows)) ])
           ~err_attrs:(fun `Db_error -> [ ("result", "db_error") ])
           load_rows)
    ]} *)

val link_span :
  ?attrs:(string * string) list ->
  trace_id:string ->
  span_id:string ->
  ('a, 'err) t ->
  ('a, 'err) t
(** Attach a {!Capabilities.span_link} to the span opened by [body]. If [body]
    has no enclosing {!named} span, the link buffers and attaches to the next
    one (mirrors the buffered-attribute semantics). *)

val with_external_parent :
  trace_id:string -> span_id:string -> ('a, 'err) t -> ('a, 'err) t
(** Compatibility wrapper for {!with_context} when only a trace ID and parent
    span ID are available. New boundary code should prefer {!Trace_context.extract}
    plus {!with_context} so trace flags, tracestate, and baggage are preserved. *)

val with_context :
  Capabilities.trace_context -> ('a, 'err) t -> ('a, 'err) t
(** Run [body] with an inbound or otherwise external trace context. The next
    opened {!named} span uses this context as parent, parent-based sampling sees
    its sampled flag, and baggage/tracestate remain visible through
    {!current_context}. *)

val current_span : (Capabilities.span_info option, 'err) t
(** Yield the {!Capabilities.span_info} of the currently active span on this
    fiber, or [None] if none is open. *)

val current_context : (Capabilities.trace_context option, 'err) t
(** Yield the current propagation context. When a span is active this is that
    span's context; otherwise it is the ambient context installed by
    {!with_context}, if any. *)

val log :
  ?level:Capabilities.log_level ->
  ?attrs:(string * string) list ->
  string ->
  (unit, 'err) t
(** Emit a structured log record to the runtime's logger. The runtime
    automatically populates the record's [trace_id]/[span_id] from the
    active span and [ts_ms] from the runtime's clock. *)

val metric_update :
  ?description:string ->
  ?unit_:string ->
  ?attrs:(string * string) list ->
  name:string ->
  kind:Capabilities.metric_kind ->
  Capabilities.metric_value ->
  (unit, 'err) t
(** Records a runtime observation, not part of the eff's success value or
    typed error channel. Runtimes without a meter may ignore it. *)

type metric
(** Description of one metric observation before the runtime timestamp is
    attached. Use {!metric} to construct values for {!metric_updates} and
    {!metric_updates_lazy}. *)

val metric :
  ?description:string ->
  ?unit_:string ->
  ?attrs:(string * string) list ->
  name:string ->
  kind:Capabilities.metric_kind ->
  Capabilities.metric_value ->
  metric
(** Build one metric observation for batched metric emission. *)

val metric_updates : metric list -> (unit, 'err) t
(** Record several metric observations with one runtime timestamp. Runtimes
    without a meter ignore the batch. *)

val metric_updates_lazy : (unit -> metric list) -> (unit, 'err) t
(** Like {!metric_updates}, but the list is built only when the active runtime
    has a meter. Use this for hot paths where collecting stats or allocating
    metric attributes is wasted when metrics are disabled. *)

val here_attr : string * int * int * int -> ('a, 'err) t -> ('a, 'err) t
(** Intended for wrappers that pass [__POS__] through unchanged; synthesized
    locations make traces harder to correlate with source. *)

val fn :
  ?kind:Capabilities.span_kind ->
  ?error_renderer:('err -> string) ->
  ?attrs:(string * string) list ->
  string * int * int * int ->
  string ->
  ('a, 'err) t ->
  ('a, 'err) t
(** [fn __POS__ __FUNCTION__ body] names [body] after the current binding and
    records the source location as a [loc] span attribute. [?attrs] attaches
    additional attributes to the same span. *)

val name : ('a, 'err) t -> string option
val collect_names : ('a, 'err) t -> string list
(** [collect_names eff] returns names that are statically present in
    [eff]'s current description.

    This is a preflight/documentation helper, not a complete runtime inventory.
    Continuation-producing nodes such as [bind], [catch], [for_each_par],
    [for_each_par_bounded], and [supervisor_scoped] are not forced or traversed,
    so names created by those continuations are intentionally absent. *)
