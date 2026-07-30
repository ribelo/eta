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

    This signature is intentionally a facade over Eta's eff algebra and
    structured concurrency. Keep
    implementation-only representation details out of this file:
    if a helper is needed only by Runtime or private modules, put it behind a
    private module such as Runtime_erasure instead of widening Effect. *)

type ('a, +'err) t

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

    This is the pipe-friendly companion to {!from_result}. Prefer
    {!sync_result} for the ordinary synchronous leaf that returns [result];
    keep [flatten_result] for hand-rolled pipelines after any effect that
    succeeds with a [result]. *)

val sync : (unit -> 'a) -> ('a, 'err) t
(** [sync f] lifts an OCaml function into an eff. The optional
    [eta_observability] package provides named tracing spans.

    Ordinary OCaml exceptions raised by [f] are unchecked defects and surface
    as {!Cause.Die}. They are not converted into the typed error channel and
    are not handled by {!bind_error}. If a synchronous leaf operation has an
    expected typed failure, prefer {!sync_result} or {!sync_option} (or return
    an explicit [result]/[option] and lift after this boundary).
    Runtime cancellation exceptions remain interruption. *)

val sync_result : (unit -> ('a, 'err) result) -> ('a, 'err) t
(** Synchronous leaf that returns an OCaml [result].

    [sync_result f] is [sync f |> flatten_result]: [Ok x] succeeds, [Error e]
    is a typed failure, and ordinary exceptions raised by [f] remain unchecked
    defects ({!Cause.Die}). This is the recommended typed sync leaf; it does
    not catch exceptions into the typed channel. *)

val sync_option : if_none:'err -> (unit -> 'a option) -> ('a, 'err) t
(** Synchronous leaf that returns an OCaml [option].

    [sync_option ~if_none f] runs [f] under {!sync}, then applies the same
    [if_none] rule as {!from_option}: [Some x] succeeds and [None] fails with
    the typed [if_none] payload. Ordinary exceptions raised by [f] remain
    unchecked defects ({!Cause.Die}); they are not converted into the typed
    channel and are not handled by {!bind_error}. Runtime cancellation
    exceptions remain interruption. *)

val async :
  register:((('a, 'err) Exit.t -> unit) -> (unit, 'err) t option) ->
  ('a, 'err) t
(** Bridge one callback registration into Eta. [register resume] runs once when
    interpreted. Registration is cancellation-protected until it returns, so it
    must return promptly. The first [resume exit] wins; later calls are dropped.
    It may resolve synchronously before [register] returns without deadlocking.
    The optional returned effect is the canceler. If interruption wins while
    pending, Eta runs it at most once and uninterruptibly; it never runs after
    resolution wins. Interruption waits, so the canceler must terminate.
    Failure is a finalizer diagnostic suppressed under the interruption.
    An exception raised by [register] follows ordinary capture as {!Cause.Die}
    and wins even if [resume] was called synchronously first.
    A runtime one-shot promise latches resolution before parking and queues a
    parked resume, so registration-to-parking wakeups cannot be lost.
    On js_of_ocaml this is the same one-shot protocol under CPS; [register]
    must loudly check required host capabilities. Eta installs no host polyfills. *)

val yield : (unit, 'err) t
(** Cooperatively yield the current Eta fiber to the active runtime backend.

    This is the backend-neutral spelling for an Eta blueprint that needs a
    scheduling yield. It delegates to the runtime contract rather than calling a
    backend primitive such as [Eio.Fiber.yield] from user code. *)

val never : ('a, 'err) t
(** An interruptible effect that never succeeds on its own.

    [never] parks the current Eta fiber by waiting on an unresolved
    backend-neutral runtime promise until it is interrupted by its parent, a
    timeout, race loser cancellation, or another runtime cancellation source. *)

val die_message : string -> ('a, 'err) t
(** Fail with an unchecked defect carrying [Failure message].

    This is sugar for a string-backed defect. It does not use the typed failure
    channel and does not introduce a new cause taxonomy. *)

val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
(** Transform the success value of an effect. In application code, the mapping
    operator from {!Syntax} is usually the more readable spelling.

    For total pure functions, [map] obeys identity and composition under Eta's
    observable exit and event behavior:
    [map Fun.id eff = eff], and
    [map f (map g eff) = map (fun value -> f (g value)) eff]. *)

val bind : ('a -> ('b, 'err) t) -> ('a, 'err) t -> ('b, 'err) t
(** Primitive dependent sequencing.

    This is the operation behind the sequencing operator from {!Syntax}. Prefer
    syntax operators in
    user-facing workflows; use [bind] directly for combinators, generated code,
    or code where pipeline style is materially clearer.

    For total continuations, [pure] and [bind] obey left identity, right
    identity, and associativity under Eta's observable exit and event behavior:
    [bind f (pure value) = f value], [bind pure eff = eff], and
    [bind g (bind f eff) = bind (fun value -> bind g (f value)) eff]. *)

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
(** The first child to produce a value is selected and the rest are cancelled.
    The selected value is returned unless cancelled-loser cleanup produces a
    finalizer diagnostic, in which case that diagnostic is returned as an error.

    Unlike JavaScript's [Promise.race], an [Exit.Error] cause does not win:
    typed failures, defects, interruptions, and finalizer causes are collected
    while [race] waits for the first success. If every child fails, their causes
    are returned concurrently.

    Losers' values are discarded by design. Resource lifetime is owned by
    scopes, not by race: a loser that holds its resource under
    {!acquire_release} / {!Semaphore.with_permits} has it released when it is
    cancelled, even if it ran to completion before losing. An acquisition whose
    ownership is carried through a value can be discarded by race; use
    {!Semaphore.with_permits_or_abort} when racing permit acquisition against an
    abort signal.

    Heterogeneous branches: map each branch into a common domain-tagged
    variant first (e.g. [Effect.map (fun v -> `Done v) work] vs.
    [Effect.map (fun () -> `Timeout) (delay d)]). Named tags beat positional
    either-types at the call site. For ordinary timeouts prefer {!timeout_as},
    which owns cancellation and finalizer semantics. *)

val par : ('a, 'err) t -> ('b, 'err) t -> ('a * 'b, 'err) t
(** Run two effects concurrently; collect both successes as a pair.
    Fail-fast: the first child failure cancels the sibling and the
    cause propagates upward.

    This is eff concurrency on the current runtime substrate, not CPU
    parallelism. Use the optional [eta_par] package for worker-domain offload
    or explicit fork-join parallel algorithms. *)

val par3 :
  ('a, 'err) t -> ('b, 'err) t -> ('c, 'err) t -> ('a * 'b * 'c, 'err) t
(** Run three effects concurrently; collect all successes as a flat triple
    in argument order, independent of completion order. Fail-fast like
    {!par}: the first child failure cancels every sibling and the cause
    propagates upward.

    Arity cap is four: for five or more effects use {!all} for homogeneous
    work or nested {!par} for heterogeneous products. *)

val par4 :
  ('a, 'err) t ->
  ('b, 'err) t ->
  ('c, 'err) t ->
  ('d, 'err) t ->
  ('a * 'b * 'c * 'd, 'err) t
(** Run four effects concurrently; collect all successes as a flat quadruple
    in argument order, independent of completion order. Fail-fast like
    {!par}: the first child failure cancels every sibling and the cause
    propagates upward.

    This is the arity cap; see {!par3} for the beyond-four rule. *)

val all : ('a, 'err) t list -> ('a list, 'err) t
(** Run every prebuilt effect concurrently, collecting results in input order.
    [all] forks one fiber per input and registers every child fiber before any
    child body starts, so no coordination child can be withheld by admission.
    Fail-fast: the first child failure cancels siblings and propagates its cause.
    Reserve [all] for finite groups requiring full admission; use {!all_bounded} for large or
    data-derived independent prebuilt effects and {!map_par} for lazy mapping. *)

val all_bounded : max_concurrent:int -> ('a, 'err) t list -> ('a list, 'err) t
(** Run prebuilt effects with at most [max_concurrent] children admitted at
    once, collecting results in input order. Fail-fast like {!all}.
    A bound smaller than a coordination group can stall when every admitted
    child waits for work from a child that has not been admitted.

    @raise Invalid_argument if [max_concurrent <= 0]. *)

val all_settled :
  ('a, 'err) t list -> (('a, 'err Cause.t) result list, 'outer_err) t
(** Collect every child outcome in input order; failures become [Error cause].
    As in {!all}, every child fiber is registered before any child body starts. *)

val map_par :
  ?max_concurrent:int ->
  ('a -> ('b, 'err) t) ->
  'a list ->
  ('b list, 'err) t
(** Map over the input concurrently; collect results in input order.
    Fail-fast like {!all}: the first child failure cancels its siblings.

    Runs at most [max_concurrent] child effects concurrently; the default is 8.
    Fewer fibers are started when the input is shorter. The bound limits
    concurrent fibers, not domain workers. This does not move arbitrary effects
    to worker domains; use the optional [eta_par] package for CPU-bound batch
    work.
    The mapper is not forced while constructing the blueprint.
    @raise Invalid_argument if [max_concurrent <= 0]. *)

val acquire_all_par :
  ?max_concurrent:int ->
  acquire:('c -> ('a, 'err) t) ->
  release:('a -> (unit, 'r) t) ->
  'c list -> ('a list, 'err) t
(** Acquire concurrently and return resources in input order. Admission matches
    {!map_par}: the default is 8 and nonpositive bounds are rejected.
    Acquire failure or interruption cancels admitted work and releases completed
    resources in reverse successful-acquisition order. A late completion is
    cleaned without transfer. Success transfers ownership to the current scope;
    releases run in that order after success, typed failure, defect, or
    interruption. Release failures use the existing finalizer cause semantics. *)

val uninterruptible : ('a, 'err) t -> ('a, 'err) t
(** Defer parent cancellation while running the wrapped eff.

    This maps to backend cancellation protection. It does not turn
    interruption into a typed failure, and it does not catch defects. *)

val interruptible : ('a, 'err) t -> ('a, 'err) t
(** Re-enable parent cancellation within a dynamically enclosing
    {!uninterruptible}. Masks stack: the innermost mask wins, and outside a mask
    this is identity. Pending interruption is delivered at entry, at successful
    exit, or by a cancellation checkpoint in the wrapped eff, at most once.
    Restoration listens to both the mask-entry parent and the entry-time current
    cancellation context. When they compete, the reason from the first
    cancellation call executed wins.

    Finalizers and [finally] stay protected. Restoration is fiber-local;
    children forked inside a mask remain masked. *)

val bind_error :
  ('err1 -> ('a, 'err2) t) -> ('a, 'err1) t -> ('a, 'err2) t
(** Bind over the typed error channel (data-last, pipeline-friendly).

    [bind_error handler eff] does not handle unchecked defects, interruption, or
    cleanup/finalizer failures. One recovery decision is made from the cause:
    the handler is not run per [Fail] leaf.

    If any uncatchable defect, interruption, or finalizer diagnostic remains,
    the handler is not invoked and the eff stays failed with those diagnostics.
    If only typed failures remain, the handler runs once with the first typed
    failure in cause order. Use [all_settled] when every branch outcome matters.

    Left identity holds for the typed channel:
    [bind_error handler (fail error) = handler error]. *)

val catch_some :
  ('err -> ('a, 'err) t option) -> ('a, 'err) t -> ('a, 'err) t
(** Selectively handle a typed failure without changing the error row.

    [catch_some handler eff] has the same catchability boundary as
    {!bind_error}: only failed exits whose cause tree contains recoverable
    typed failures and no defects, interruption, or finalizer diagnostics.

    When only typed failures remain, [catch_some] inspects the first typed
    failure in cause order. [Some recovery] runs that recovery effect. [None]
    preserves the original cause exactly, including composite typed failures. *)

val fold :
  ok:('a -> 'b) -> error:('err -> 'b) -> ('a, 'err) t -> ('b, 'outer) t
(** Pure both-channel fold; mirrors [Result.fold].

    [fold ~ok ~error eff] maps success with [ok] and catchable typed failure
    with [error], succeeding with the pure result. Defects, interruption, and
    finalizer diagnostics are not folded. If [ok] or [error] raises, the
    exception is an unchecked defect.

    For total pure functions it is coherent with [map] and [bind_error]:
    [fold ~ok ~error eff =
     bind_error (fun err -> pure (error err)) (map ok eff)]. *)

val or_else : (unit -> ('a, 'err2) t) -> ('a, 'err1) t -> ('a, 'err2) t
(** Recover from any typed failure with a lazy fallback effect.

    [or_else fallback eff] is shorthand for
    [bind_error (fun _ -> fallback ()) eff]. Successful values pass through
    without evaluating [fallback]. The fallback runs only for catchable typed
    failures. Defects, interruption, and finalizer diagnostics are not handled,
    matching {!bind_error}. *)

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

val discard : ('a, 'err) t -> (unit, 'err) t
(** Discard a successful value; every cause propagates unchanged.

    [discard eff] is [map (fun _ -> ()) eff]. Typed failures, defects,
    interruption, and finalizer diagnostics are not recovered. Prefer this
    when only the success payload is unwanted. *)

val ignore_errors : ('a, 'err1) t -> (unit, 'err2) t
(** Discard a successful value and suppress typed failures.

    [ignore_errors eff] succeeds with [()] when [eff] succeeds or fails only
    with typed failures. Defects, interruption, and finalizer diagnostics
    remain visible. Use it for best-effort cleanup, refresh, or notification
    effects; use {!discard} when typed failures must still fail the workflow. *)

val to_result : ('a, 'err1) t -> (('a, 'err1) result, 'err2) t
(** Materialize the typed failure channel into an ordinary OCaml [result].

    [to_result eff] succeeds with [Ok value] when [eff] succeeds and with
    [Error err] when [eff] fails with a typed failure. Defects, interruption,
    and finalizer diagnostics are not captured; they remain failed Eta causes.
    Use this when a workflow should keep going and handle success/failure as
    data without leaving Eta's runtime boundary. *)

val to_option : ('a, 'err1) t -> ('a option, 'err2) t
(** Materialize success as [Some value] and typed failure as [None].

    [to_option] discards typed failure payloads. Defects, interruption, and
    finalizer diagnostics are not captured; they remain failed Eta causes.
    Use {!to_result} when the typed failure value matters. *)

val to_exit : ('a, 'err1) t -> (('a, 'err1) Exit.t, 'err2) t
(** Materialize the full Eta exit as a success value.

    [to_exit eff] succeeds with [Exit.Ok value] when [eff] succeeds and with
    [Exit.Error cause] when [eff] fails with a typed failure, defect,
    interruption, or finalizer diagnostic. *)

val map_error : ('err1 -> 'err2) -> ('a, 'err1) t -> ('a, 'err2) t
(** Transform typed failures while preserving unchecked defects, interruption,
    and the surrounding cause structure. [Cause.Fail] values in the primary
    cause tree are mapped, including failures nested under [Sequential] and
    [Concurrent]. Cleanup/finalizer failures are already outside the typed
    channel in {!Cause.Finalizer} nodes and are preserved unchanged, including
    [Cause.Suppressed.finalizer] branches. *)

val or_die : ('err -> exn) -> ('a, 'err) t -> ('a, 'outer) t
(** Convert typed failures into unchecked defects.

    [or_die to_exn eff] preserves successful values. On failure, every
    [Cause.Fail err] in the primary cause tree becomes a [Cause.Die] built from
    [to_exn err]. [Sequential] and [Concurrent] structure is preserved.
    Existing defects, interruption, and finalizer diagnostics are preserved.
    For [Cause.Suppressed], only the primary cause is converted; the structured
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
  schedule:('err, 'schedule_out) Schedule.t ->
  while_:('err -> bool) ->
  ('a, 'err) t ->
  ('a, 'err) t
(** Retry an effect while the schedule continues and [while_] accepts the
    typed failure. The typed failure is passed to the schedule as input. To
    observe every attempt, including the initial one, instrument the source
    effect itself before passing it to [retry]. Schedule-local boundaries such
    as terminal decisions and policy-generated outputs are not observable by
    that recipe.

    For composites, [retry] has the same catchability boundary as {!bind_error}
    and {!retry_or_else}: it uses the first typed failure when present and no
    uncatchable diagnostic exists. Causes without typed failures, rejected causes,
    and uncatchable exits preserve their source; exhaustion preserves the complete terminal cause. *)

val retry_or_else :
  schedule:('err1, 'schedule_out) Schedule.t ->
  while_:('err1 -> bool) ->
  or_else:('err1 -> 'schedule_out option -> ('a, 'err2) t) ->
  ('a, 'err1) t ->
  ('a, 'err2) t
(** Retry an effect while the schedule continues and [while_] accepts the
    typed failure, then run [or_else] with the final typed failure when the
    predicate rejects it or the schedule is exhausted.

    The typed failure is passed to the schedule as input. [or_else] receives
    the latest schedule output when at least one schedule step has run,
    including the terminal [Done] output when the schedule is exhausted. It
    receives [None] when [while_] rejects the first typed failure before any
    schedule step. For composite causes, [retry_or_else] follows {!bind_error}:
    it handles only causes whose primary tree contains typed failures and no
    uncatchable defects, interruption, or finalizer diagnostics, and it uses the
    first typed failure in cause order. Uncatchable diagnostics are not retried
    and do not run [or_else].

    To observe every attempt, including the initial one, instrument the source
    effect itself before passing it to [retry_or_else]. This does not expose
    schedule-local boundaries. [or_else] failures become the result normally;
    the original typed failure is not suppressed or reported as a finalizer
    diagnostic. *)

val now_ms : (int, 'err) t
(** Read the active monotonic runtime clock in milliseconds. This is runtime
    elapsed time, not wall/civil time. Runtime constructors and tests can
    override this clock with their [?now_ms] argument. *)

val fresh : unit -> (int, 'err) t
(** Return the next value from the active runtime's monotonic counter.

    Values are unique and strictly increasing only within one runtime. They are
    not globally unique: distinct runtimes, including runtimes on different
    domains, may return the same values. Add an application-owned namespace when
    correlating identifiers across runtimes. A newly created [Eta_test] runtime
    resets the counter, so test programs replay deterministically. Exhaustion
    ([2^62] pulls on 64-bit) fails loudly with [Invalid_argument] rather than
    wrapping. *)

val fresh_named : string -> (string, 'err) t
(** [fresh_named prefix] formats the next {!fresh} value as ["prefix-N"]. It is
    convenience formatting over the same runtime counter, not a second counter. *)

val sleep : Duration.t -> (unit, 'err) t
(** Sleep through the active monotonic runtime clock. The sleeper and
    {!now_ms} must use the same time base. Runtime constructors and tests can
    override this sleeper with their [?sleep] argument. *)

val delay : Duration.t -> ('a, 'err) t -> ('a, 'err) t
val timed : ('a, 'err) t -> (Duration.t * 'a, 'err) t
(** Measure an effect with the active monotonic runtime clock.

    On success, [timed eff] returns [(elapsed, value)]. Typed failures,
    defects, interruption, and finalizer diagnostics are preserved as the
    original failed outcome. *)

val timeout : Duration.t -> ('a, [> `Timeout ] as 'err) t -> ('a, 'err) t
val timeout_as :
  Duration.t -> on_timeout:'err -> ('a, 'err) t -> ('a, 'err) t
(** Like {!timeout}, but fails with [on_timeout] instead of widening the error
    row with raw Timeout. *)
val repeat :
  schedule:('a, 'output) Schedule.t ->
  ('a, 'err) t ->
  ('output, 'err) t
(** Repeat a successful effect according to [schedule].

    The source effect is evaluated once before the schedule is stepped. Each
    successful value is passed to the schedule as input. When the schedule
    continues, Eta sleeps for the step delay and runs the source again. When the
    schedule is done, [repeat] succeeds with the schedule output. To observe
    every source evaluation, including the initial one, instrument the source
    effect itself before passing it to [repeat]. This does not expose
    schedule-local boundaries. The first source failure stops the loop. *)

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
    body-bounded resource lifetimes, or {!acquire_release} and {!with_scope} when
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
    failure after a failed body.

    For homogeneous parallel acquisition into an enclosing scope, use
    {!acquire_all_par} rather than composing this operation with {!map_par}. *)

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
    enclosing runtime or {!with_scope} boundary rather than just the callback
    body. *)

val with_resource_exit :
  acquire:('a, 'err) t ->
  release:('a -> ('b, 'err) Exit.t -> (unit, 'release_err) t) ->
  ('a -> ('b, 'err) t) ->
  ('b, 'err) t
(** Friendly name for {!acquire_use_release_exit}. *)

val with_scope : ('a, 'err) t -> ('a, 'err) t
(** Open a resource scope around an effect.

    Resources registered with {!acquire_release} inside [with_scope] are
    released when the scope exits, in reverse acquisition order. Finalizers run
    on success, typed failure, unchecked defect, and cancellation.

    Scopes compose: nested [with_scope] blocks release their own resources
    before the outer scope continues. Use this for resource lifetimes that
    should not extend to the runtime boundary. Use {!acquire_all_par} to acquire
    several homogeneous independent resources in parallel into this scope. *)

val with_background :
  ?name:string -> (unit, 'err) t -> (unit -> ('a, 'err) t) -> ('a, 'err) t
(** Run [background] while [use] executes. Fail-fast: if [background] fails
    first, [use] is cancelled and awaited, its finalizers run, and the
    background cause propagates, like {!par}'s sibling rule. If [use] finishes
    first, [background] is cancelled and awaited. A racing background failure
    and body completion are linearized by terminal-exit publication order,
    matching {!par}'s first-observed rule; the first publication wins. *)

val with_supervised_background :
  ?name:string -> (unit, 'err) t -> (unit -> ('a, 'err) t) -> ('a, 'err) t
(** Run [background] as a supervised child while [use] executes. Background
    failure is recorded by the supervisor and does not affect [use] before it
    ends. When [use] returns or fails, the child is cancelled and awaited. *)

val supervisor_scoped :
  ?max_failures:int -> ('a, 'err) supervisor_body -> ('a, 'err) t
(** Low-level abstract supervisor-scope runner used by {!Supervisor}. Prefer
    {!Supervisor.scoped} and {!Supervisor.Scope} in user code. *)

val supervisor_yield : ('s, unit, 'err) supervisor_scope
(** Low-level supervisor-scope yield used by {!Supervisor.Scope}. The
    supervisor-scope primitives intentionally do not expose the interpreter
    AST constructors. *)

val with_clock : Capabilities.clock -> ('a, 'err) t -> ('a, 'err) t
(** Dynamically replace the fiber-local runtime clock for [body]. Children
    inherit it at fork without join-merge. Success, typed failure, defect, or
    interruption restores it. Innermost wins; [par] siblings are isolated.
    Leaves capture it at call time; in-flight sleeps are unchanged. Daemons keep
    it after scope exit.
    This governs clock reads/sleeps, including the [now_ms] and [sleep] fields
    exposed to {!Spi.Expert.contract}, and their users: delay, timed, timeout,
    retry/repeat, timestamps, and span timing.

    {[ Effect.with_clock (Eta_test.Test_clock.as_capability clock) program ]} *)

val with_random : Capabilities.random -> ('a, 'err) t -> ('a, 'err) t
(** Dynamically replace the fiber-local runtime random source for [body].
    Children inherit it at fork without join-merge. Success, typed failure,
    defect, and interruption restore it.
    Innermost wins and [par] siblings are isolated. Runtime random operations
    capture it when called; already-started operations are unchanged. A daemon
    retains its fork-time source after this scope exits. This governs
    [retry]/[repeat] schedule jitter and runtime-generated trace identifiers,
    not explicitly passed application random tokens. *)

val name : ('a, 'err) t -> string option

val describe : ('a, 'err) t -> string
(** Render the statically constructed blueprint as a deterministic tree without
    evaluating it.

    The node labels are [Pure], [Fail], [Custom], [Custom("name")], [Map], and
    [Bind], with two spaces per child depth and no trailing newline. A [Bind]
    includes its visible input subtree followed by a literal [<bind …>] child;
    the continuation is never forced. Opaque custom/wrapper evaluators remain
    leaves rather than pretending their runtime work is inspectable. *)
