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

    This signature is intentionally a facade over Eta's effect algebra,
    structured concurrency, observability hooks, and blocking bridge. Keep
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

val sync : (unit -> 'a) @ many -> ('a, 'err) t
(** [sync f] lifts an OCaml function into an effect. Use {!Effect.named} to
    attach a span name for tracing.

    Ordinary OCaml exceptions raised by [f] are unchecked defects and surface
    as {!Cause.Die}. They are not converted into the typed error channel and
    are not caught by {!catch}. Return an explicit [result] and use
    {!from_result} when a leaf operation has an expected typed failure.
    [Eio.Cancel.Cancelled _] remains interruption. *)

module Blocking : sig
  type ('a, 'err) effect = ('a, 'err) t

  module Pool : sig
    type t

    type queue_policy : immutable_data = Wait | Reject
    type shutdown_policy : immutable_data = Drain | Detach_started

    type config : immutable_data = {
      max_threads : int;
      max_queued : int;
      queue_policy : queue_policy;
      shutdown_policy : shutdown_policy;
    }

    type stats : immutable_data = {
      active : int;
      queued : int;
      completed : int;
      rejected : int;
      cancelled_before_start : int;
      detached : int;
    }

    type runner = {
      run_in_systhread : 'a. label:string -> (unit -> 'a) -> 'a;
    }
    (** Worker substrate used by systhread blocking pools. In normal compiled
        applications the default runner is sufficient. In [dune utop] workflows
        that load Eta before [eio_main], use {!runner_of_eio_unix}. *)

    module type EIO_UNIX = sig
      val run_in_systhread : ?label:string -> (unit -> 'a) -> 'a
    end
    (** Minimal host module shape needed by {!runner_of_eio_unix}. *)

    val default_runner : runner

    val runner_of_eio_unix : (module EIO_UNIX) -> runner
    (** Build a blocking runner from the host application's [Eio_unix] module.
        This is mainly for [dune utop] workflows where Eta is loaded before
        [eio_main]. For a runtime-owned default blocking pool, prefer
        {!Runtime.with_host_eio}. Use this helper directly when creating a
        standalone pool with {!create}. *)

    val create : ?name:string -> ?runner:runner -> config -> t
    (** Create a bounded blocking pool.

        Use separate pools for independent blocking resource classes, such as
        database calls, filesystem work, and third-party synchronous SDKs. One
        full pool does not back-pressure another.

        The runtime-owned default pool uses [max_threads = 128],
        [max_queued = 64], [queue_policy = Wait], and
        [shutdown_policy = Drain]. Tune explicitly for applications with known
        blocking I/O concurrency. *)

    val shutdown_policy : t -> shutdown_policy
    (** Return the pool's started-work shutdown policy. Connectors that lease
        non-thread-safe resources use this to reject detached started work. *)

    val stats : t -> stats
    (** Snapshot pool counters. [active] is started work still running;
        [queued] is admitted work waiting for an active slot; [completed] is
        started work that reached a value or exception; [rejected] counts
        [Reject] submissions refused because the pool was full;
        [cancelled_before_start] counts admitted jobs removed before start by
        parent cancellation; [detached] counts started jobs no longer awaited by
        the caller or by [shutdown] because the pool used [Detach_started]. *)

    val shutdown : t -> (unit, 'err) effect
    (** Stop accepting new work. [Drain] waits for admitted work to finish.
        [Detach_started] returns promptly and records still-running started
        work as detached. *)
  end

  val submit :
    ?pool:Pool.t ->
    ?name:string ->
    ?on_cancel:(unit -> unit) ->
    (unit -> 'a) @ many ->
    ('a, 'err) effect
  (** Namespaced spelling for {!blocking}. *)
end

val blocking :
  ?pool:Blocking.Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> 'a) @ many ->
  ('a, 'err) t
(** Run [f ()] on a bounded blocking pool.

    Use this for legacy synchronous I/O such as blocking DB clients, filesystem
    libraries, synchronous SDKs, and blocking C bindings. Do not use it for
    CPU-bound work; use {!Island.run} or {!Island.map} instead.

    Running callbacks are not preempted. Parent cancellation interrupts queued
    work, but started work must finish unless the pool uses
    [Detach_started] or [?on_cancel] cooperatively unblocks it.

    Worker callbacks must not call Eio operations, run Eta runtimes, submit
    nested blocking jobs, or resolve parent-domain promises. [?name] labels
    tracing and metrics. [?on_cancel] must be thread-safe with respect to [f]. *)

val blocking_result :
  ?pool:Blocking.Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> ('a, 'err) result) @ many ->
  ('a, 'err) t
(** [blocking_result f] runs [f] like {!blocking} and lifts its OCaml
    [result] into Eta's typed failure channel. Exceptions raised by [f] remain
    unchecked defects, exactly as with {!blocking}. *)

val blocking_result_timeout :
  ?pool:Blocking.Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  timeout:Duration.t ->
  on_timeout:'err ->
  (unit -> ('a, 'err) result) @ many ->
  ('a, 'err) t
(** [blocking_result_timeout ~timeout ~on_timeout f] runs [f] like
    {!blocking_result} and races the caller's wait against [timeout]. The
    timeout bounds the caller's wait; it is not CPU/thread preemption. If [f]
    has already started in a [Drain] blocking pool, Eta returns [on_timeout] to
    the caller but keeps the started job under pool accounting until it finishes.
    If [f] is still queued when the timeout wins, Eta cancels it before start.

    If the timeout wins, the effect fails with [on_timeout]. [?on_cancel] is
    invoked once so [f] can cooperatively unblock. If the blocking operation
    wins after parent cancellation reached the fiber, Eta checks the
    cancellation state before publishing the success or typed failure. *)

val map : ('a -> 'b) @ many -> ('a, 'err) t -> ('b, 'err) t
val bind : ('a -> ('b, 'err) t) @ many -> ('a, 'err) t -> ('b, 'err) t
val ( >>= ) : ('a, 'err) t -> ('a -> ('b, 'err) t) @ many -> ('b, 'err) t

val tap : ('a -> (unit, 'err) t) @ many -> ('a, 'err) t -> ('a, 'err) t

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

    This is effect concurrency on the current Eio runtime, not CPU
    parallelism. Use {!Island.run} / {!Island.map} for portable worker-domain
    offload, or {!Par} for explicit fork-join
    parallel algorithms. *)

val all : ('a, 'err) t list -> ('a list, 'err) t
(** Run effects concurrently, collecting results in input order.
    Fail-fast: the first child failure cancels the others; the cause
    of the first observed failure propagates. *)

val all_settled :
  ('a, 'err) t list -> (('a, 'err Cause.t) result list, 'outer_err) t
(** Run effects concurrently and collect every child outcome in input order.
    Child failures are returned as [Error cause] values instead of failing the
    outer effect. *)

val for_each_par : 'x list -> ('x -> ('a, 'err) t) @ many -> ('a list, 'err) t
(** Map over [xs] concurrently with [f]; collect results in input order.
    Fail-fast like {!all}.

    This runs child effects as concurrent fibers on the current runtime
    substrate. It does not move arbitrary effects to worker domains; use
    {!Island.map} for portable CPU-bound batch work. *)

val for_each_par_bounded :
  max:int -> 'x list -> ('x -> ('a, 'err) t) @ many -> ('a list, 'err) t
(** Map over [xs] with at most [max] child effects running at once. Results
    are returned in input order and failures are fail-fast like {!for_each_par}.
    The bound limits concurrent fibers, not domain workers.
    @raise Invalid_argument if [max <= 0]. *)

val uninterruptible : ('a, 'err) t -> ('a, 'err) t
(** Defer parent cancellation while running the wrapped effect.

    This maps to [Eio.Cancel.protect]. It does not turn interruption
    into a typed failure, and it does not catch defects. *)

val catch :
  ('err1 -> ('a, 'err2) t) @ many -> ('a, 'err1) t -> ('a, 'err2) t
(** Handle typed failures in an effect's cause tree.

    [catch handler effect] does not catch unchecked defects, interruption, or
    cleanup/finalizer failures. This matches the ordinary typed-error recovery
    shape in ZIO [catchAll]/[foldZIO] and effect-ts [catch]/[findError]: one
    recovery decision is made from the cause, rather than traversing every
    [Fail] leaf and running one handler per branch.

    If any uncatchable defect, interruption, or finalizer diagnostic remains in
    the cause tree, the handler is not invoked and the effect stays failed with
    those uncatchable diagnostics. This avoids running recovery side effects for
    an operation that still fails, and avoids preserving old typed [Fail]
    payloads after [catch] changes the error type.

    If only typed failures remain, [catch] invokes the handler once with the
    first typed failure in cause order. Other concurrent/sequential typed
    failures are not recoverable values; use [all_settled] or explicit result
    values when every branch outcome matters. Recover or ignore cleanup failure
    inside the cleanup effect itself. *)

val map_error : ('err1 -> 'err2) @ many -> ('a, 'err1) t -> ('a, 'err2) t
(** Transform typed failures while preserving unchecked defects, interruption,
    and the surrounding cause structure. [Cause.Fail] values in the primary
    cause tree are mapped, including failures nested under [Sequential] and
    [Concurrent]. Cleanup/finalizer failures are already rendered into
    {!Cause.Finalizer} nodes and are preserved unchanged, including
    [Cause.Suppressed.finalizer] branches. *)

val tap_error : ('err -> unit) @ many -> ('a, 'err) t -> ('a, 'err) t
(** Run an observer when the effect fails with a typed error, then rethrow the
    original typed failure. If the observer raises, the runtime reports a
    suppressed cause with the original [Cause.Fail] as [primary] and the
    observer exception as [finalizer], so diagnostics retain both failures. *)

val retry : Schedule.t -> ('err -> bool) @ many -> ('a, 'err) t -> ('a, 'err) t

val delay : Duration.t -> ('a, 'err) t -> ('a, 'err) t
val timeout : Duration.t -> ('a, [> `Timeout ] as 'err) t -> ('a, 'err) t
val timeout_as :
  Duration.t -> on_timeout:'err -> ('a, 'err) t -> ('a, 'err) t
(** Like {!timeout}, but fails with [on_timeout] instead of widening the error
    row with raw Timeout. *)
val repeat : Schedule.t -> (unit, 'err) t -> (unit, 'err) t

val finally : (unit, 'cleanup_err) t -> ('a, 'err) t -> ('a, 'err) t
(** [finally cleanup effect] runs [cleanup] after [effect] settles, on success,
    typed failure, unchecked defect, or cancellation.

    [cleanup] runs in a cancellation-protected cleanup frame. If [effect]
    succeeds but [cleanup] fails, the cleanup failure is reported as
    [Cause.Finalizer]. If both fail, the cleanup failure is reported as a
    suppressed finalizer failure under the primary cause, matching
    {!acquire_release} finalizer reporting.

    This is for one-shot cleanup around an effect. Use {!acquire_release} and
    {!scoped} for resource lifetimes. *)

val acquire_release :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'release_err) t) ->
  ('a, 'err) t
(** Acquire a resource and register [release] to run when the current runtime
    boundary, scope, supervisor scope, or daemon body exits. The release effect
    runs on success and on typed failure; release failures are reported as
    [Cause.Finalizer] after a successful body or suppressed onto the primary
    failure after a failed body. *)

val acquire_use_release :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'release_err) t) ->
  ('a -> ('b, 'err) t) @ many ->
  ('b, 'err) t
(** Acquire a resource, run [body], and release it when [body] finishes.

    This is a lexical bracket. Unlike {!acquire_release}, it opens a local scope
    around [body], so repeated [acquire_use_release] calls do not retain
    resources until the surrounding runtime boundary exits. Release ordering,
    cancellation protection, and suppressed finalizer failure reporting match
    scoped {!acquire_release}. *)

val scoped : ('a, 'err) t -> ('a, 'err) t

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

val with_error_renderer : ('err -> string) @ many -> ('a, 'err) t -> ('a, 'err) t
(** Render typed failures in observability span status and exception events for
    the wrapped effect. The renderer is scoped to this effect's error channel. *)

val suppress_observability : ('a, 'err) t -> ('a, 'err) t
(** Run the wrapped effect without emitting tracer, logger, or meter events
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
    by the wrapped effect. *)

val annotate_all : (string * string) list -> ('a, 'err) t -> ('a, 'err) t
(** Attach several span attributes with the same semantics as {!annotate}. The
    list order is preserved. *)

val event : ?attrs:(string * string) list -> string -> (unit, 'err) t
(** Add an event to the currently active span. If tracing is disabled or no span
    is active, this is a no-op. Use this for structured progress markers inside
    a span; use {!log} for log records and {!metric_update} for metrics. *)

val with_result_attrs :
  ok_attrs:('a -> (string * string) list) ->
  err_attrs:('err -> (string * string) list) ->
  ('a, 'err) t ->
  ('a, 'err) t
(** Attach attributes derived from the effect outcome to the active span and
    preserve the original result.

    [ok_attrs] is evaluated after success. [err_attrs] is evaluated for every
    typed [Cause.Fail] in the failure cause. Defects and interruption are not
    passed to [err_attrs].

    The attributes are recorded only when a span is active at the point the
    wrapped effect settles. Put this combinator inside {!named} or {!fn} when
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
(** Records a runtime observation, not part of the effect's success value or
    typed error channel. Runtimes without a meter may ignore it. *)

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
(** [collect_names effect] returns names that are statically present in
    [effect]'s current description.

    This is a preflight/documentation helper, not a complete runtime inventory.
    Continuation-producing nodes such as [bind], [catch], [for_each_par],
    [for_each_par_bounded], and [supervisor_scoped] are not forced or traversed,
    so names created by those continuations are intentionally absent. *)
