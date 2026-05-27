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
    ZIO-style environment or layer graph. *)

type ('a, 'err) t

type ('s, 'a, 'err) supervisor_scope =
  | Supervisor_pure : 'a -> (_, 'a, _) supervisor_scope
  | Supervisor_lift : ('a, 'err) t -> (_, 'a, 'err) supervisor_scope
  | Supervisor_fail : 'err -> (_, _, 'err) supervisor_scope
  | Supervisor_bind :
      ('s, 'b, 'err) supervisor_scope
      * ('b -> ('s, 'a, 'err) supervisor_scope)
      -> ('s, 'a, 'err) supervisor_scope
  | Supervisor_start :
      ('s, 'err) supervisor
      * ('s, 'a, 'err) supervisor_scope
      -> ('s, ('s, 'err, 'a) supervisor_child, _) supervisor_scope
  | Supervisor_await :
      ('s, 'err, 'a) supervisor_child -> ('s, 'a, 'err) supervisor_scope
  | Supervisor_cancel :
      ('s, 'err, _) supervisor_child -> ('s, unit, 'err) supervisor_scope
  | Supervisor_failures :
      ('s, 'err) supervisor -> ('s, 'err Cause.t list, _) supervisor_scope
  | Supervisor_check :
      ('s, [> `Supervisor_failed of int ] as 'err) supervisor
      -> ('s, unit, 'err) supervisor_scope
  | Supervisor_yield : ('s, unit, _) supervisor_scope

and ('a, 'err) supervisor_body = {
  run : 's. ('s, 'err) supervisor -> ('s, 'a, 'err) supervisor_scope;
}

and ('s, !'err) supervisor
and ('s, !'err, !'a) supervisor_child

val pure : 'a -> ('a, 'err) t
val fail : 'err -> ('a, 'err) t
val unit : (unit, 'err) t

val sync : (unit -> 'a) -> ('a, 'err) t
(** [sync f] lifts an OCaml function into an effect. Use {!Effect.named} to
    attach a span name for tracing. *)

val island :
  ('input : immutable_data) ('output : immutable_data).
  ?name:string ->
  ('input -> 'output) @ portable ->
  'input ->
  ('output, 'err) t
(** Portable twin of {!sync} for one domain-offloaded callback.

    Anything accepted by [island] can also be expressed with {!sync}; the
    reverse is deliberately false because [island] requires a [@ portable]
    callback and portable input/output values. The runtime must be configured
    with an island pool; Eta never silently falls back to same-domain
    execution. No timeout, cancellation, preemption, streaming/online queueing,
    portable AST, or portable Resource/Supervisor/Eta_stream/OTel behavior is
    implied by this primitive. *)

module Island : sig
  type worker_die = {
    kind : string;
    message : string;
    backtrace : string option;
  }
  (** Diagnostic returned when a worker-domain callback raises before producing
      its declared result. v1 keeps this portable and intentionally smaller than
      {!Cause.t}; raw causes do not cross the island boundary. *)

  type ('a : immutable_data, 'e : immutable_data) settled =
    | Ok of 'a
    | Error of 'e
    | Worker_died of worker_die
  (** Per-item result for {!all_settled}. [Ok] and [Error] are the callback's
      own result channel; [Worker_died] is an unchecked worker crash. *)

  type pool
  (** Reusable heartbeat-backed island pool. Create it once, pass it to the
      runtime or to a batch override, and shut it down at program exit. Pool
      creation is intentionally not hidden because it is comparatively
      expensive and because missing configuration must fail loudly. *)

  val map :
    ('input : immutable_data) ('output : immutable_data).
    ?name:string ->
    ?pool:pool ->
    f:('input -> 'output) @ portable ->
    'input list ->
    ('output list, 'err) t
  (** Run a finite batch of portable callbacks and return results in input
      order. Worker crashes fail the outer effect as defects. *)

  val map_result :
    ('input : immutable_data)
    ('output : immutable_data)
    ('error : immutable_data).
    ?name:string ->
    ?pool:pool ->
    f:('input -> ('output, 'error) result) @ portable ->
    'input list ->
    (('output, 'error) result list, 'err) t
  (** Like {!map}, but the portable callback returns a typed per-item [result].
      Callback [Error _] values are returned in place; worker crashes still fail
      the outer effect as defects. *)

  val all_settled :
    ('input : immutable_data)
    ('output : immutable_data)
    ('error : immutable_data).
    ?name:string ->
    ?pool:pool ->
    f:('input -> ('output, 'error) result) @ portable ->
    'input list ->
    (('output, 'error) settled list, 'err) t
  (** Run a finite batch and return one settled outcome per input, preserving
      input order. Worker crashes are represented as [Worker_died] values
      instead of aborting siblings. *)

  module Pool : sig
    type t = pool

    val create : ?domains:int -> unit -> t
    (** Create a reusable island pool. [domains] defaults to [2].
        @raise Invalid_argument if [domains <= 0]. *)

    val shutdown : t -> unit
    (** Stop the pool. Calling it more than once is harmless; submitting work to
        a stopped pool raises [Invalid_argument]. *)
  end
end

module Blocking : sig
  type ('a, 'err) effect = ('a, 'err) t

  module Pool : sig
    type t

    type queue_policy = Wait | Reject
    type shutdown_policy = Drain | Detach_started

    type config = {
      max_threads : int;
      max_queued : int;
      queue_policy : queue_policy;
      shutdown_policy : shutdown_policy;
    }

    type stats = {
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
      val run_in_systhread : label:string -> (unit -> 'a) -> 'a
    end
    (** Minimal host module shape needed by {!runner_of_eio_unix}. *)

    val default_runner : runner

    val runner_of_eio_unix : (module EIO_UNIX) -> runner
    (** Build a blocking runner from the host application's [Eio_unix] module.
        This is mainly for [dune utop] workflows where Eta is loaded before
        [eio_main]. For a runtime-owned default blocking pool, prefer
        {!Runtime.with_host_eio_unix}. Use this helper directly when creating a
        standalone pool with {!create}. *)

    val create : ?name:string -> ?runner:runner -> config -> t
    (** Create a bounded blocking pool.

        Use a separate pool per resource class when one class can saturate
        another: database calls, filesystem operations, and third-party SDK
        calls should usually have independent pools.

        Example:

        {[
          let db_pool =
            Effect.Blocking.Pool.create ~name:"db"
              {
                max_threads = 32;
                max_queued = 64;
                queue_policy = Wait;
                shutdown_policy = Drain;
              }

          let fs_pool =
            Effect.Blocking.Pool.create ~name:"fs"
              {
                max_threads = 128;
                max_queued = 64;
                queue_policy = Wait;
                shutdown_policy = Drain;
              }
        ]}

        Pools are independent: one full pool does not back-pressure another.
        The runtime-owned default pool uses [max_threads = 128],
        [max_queued = 64], [queue_policy = Wait], and
        [shutdown_policy = Drain]. That thread count comes from the
        Eta-OxCaml-q73 measurement matrix: num_cpu/2, num_cpu, num_cpu*2,
        and fixed 32 failed the mixed workload heartbeat budget on this host;
        fixed 128 met the budget and fixed 512 did not improve the measured
        workload. Tune explicitly for applications with known higher blocking
        I/O concurrency. *)

    val create_domain_isolated : ?name:string -> config -> t
    (** Warning: create a domain-isolated blocking pool. Use this ONLY for
        legacy C bindings that hold the OCaml runtime lock during blocking
        work (compression, crypto, sync DB clients without nonblocking polling,
        etc.).

        Cost: started callbacks run in separate OCaml domains. Do not create
        many of these pools and do not use this as a general-purpose parallel
        execution API.

        Safety: callbacks must not capture Eio handles, Eta runtime state, or
        any value that is not safe to use across domains. Doing so is undefined
        behavior.

        [Pool.create] is sufficient for blocking calls that release the runtime
        lock, including well-behaved C bindings and Unix syscalls through Eio's
        systhread substrate. Choose this constructor only when you have
        measured the lock-hold case. *)

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
    (unit -> 'a) ->
    ('a, 'err) effect
  (** Namespaced spelling for {!blocking}. *)
end

val blocking :
  ?pool:Blocking.Pool.t ->
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> 'a) ->
  ('a, 'err) t
(** [Effect.blocking f] runs [f ()] on a bounded blocking pool. Use this for
    legacy synchronous I/O that cannot or should not be rewritten to Eio:
    old DB clients, blocking filesystem libraries, sync SDKs, and blocking C
    bindings.

    Anti-pattern: do not call [f ()] directly inside an Eio fiber for legacy
    blocking work. The V-Blocking-A research measured about 49ms heartbeat
    freeze for a 50ms direct blocking call. Always go through
    [Effect.blocking].

    Anti-pattern: do not use [Effect.blocking] for CPU-bound work. Blocking
    workers are an I/O escape hatch, not a CPU scheduler. Use {!Effect.island}
    for one portable CPU callback or {!Effect.Island.map} for a finite batch.

    Effect.blocking does NOT preempt running callbacks. Parent cancellation
    while a job is started is honored only when the pool is configured with
    [shutdown_policy = Detach_started] or when [?on_cancel] cooperatively
    unblocks the underlying operation.

    Blocking worker callbacks are ordinary synchronous OCaml functions. They may
    call legacy blocking libraries. They must not call Eio operations, run Eta
    runtimes, submit nested blocking jobs, or resolve parent-domain promises as
    supported API. Doing any of those is undefined behavior; Eta does not
    guarantee deadlock, panic, or correctness for it.

    The pool defaults to the runtime-owned pool. For resource isolation
    (database connections, filesystem operations, third-party SDK calls), pass
    an explicit [?pool] created by {!Blocking.Pool.create}.

    For lock-holding C bindings, see {!Blocking.Pool.create_domain_isolated}.
    The [?name] label propagates to tracing and metrics as the blocking
    operation name.

    [?on_cancel] runs in the calling domain when parent cancellation reaches a
    started blocking job. Use it only for thread-safe cancellation hooks such as
    [sqlite3_interrupt]. The hook must be thread-safe with respect to the
    worker callback it is trying to interrupt. It must not call Eio operations,
    Eta runtimes, or submit nested blocking jobs. If it raises, the blocking
    effect raises that exception after the worker callback returns. *)

val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
val bind : ('a -> ('b, 'err) t) -> ('a, 'err) t -> ('b, 'err) t
val ( >>= ) : ('a, 'err) t -> ('a -> ('b, 'err) t) -> ('b, 'err) t

val tap : ('a -> (unit, 'err) t) -> ('a, 'err) t -> ('a, 'err) t

val seq : (unit, 'err) t -> (unit, 'err) t -> (unit, 'err) t
val concat : (unit, 'err) t list -> (unit, 'err) t

val race : ('a, 'err) t list -> ('a, 'err) t
(** First child to produce a value wins; the rest are cancelled. *)

val par : ('a, 'err) t -> ('b, 'err) t -> ('a * 'b, 'err) t
(** Run two effects concurrently; collect both successes as a pair.
    Fail-fast: the first child failure cancels the sibling and the
    cause propagates upward. *)

val all : ('a, 'err) t list -> ('a list, 'err) t
(** Run effects concurrently, collecting results in input order.
    Fail-fast: the first child failure cancels the others; the cause
    of the first observed failure propagates. *)

val all_settled :
  ('a, 'err) t list -> (('a, 'err Cause.t) result list, 'outer_err) t
(** Run effects concurrently and collect every child outcome in input order.
    Child failures are returned as [Error cause] values instead of failing the
    outer effect. *)

val for_each_par : 'x list -> ('x -> ('a, 'err) t) -> ('a list, 'err) t
(** Map over [xs] concurrently with [f]; collect results in input order.
    Fail-fast like {!all}. *)

val for_each_par_bounded :
  max:int -> 'x list -> ('x -> ('a, 'err) t) -> ('a list, 'err) t
(** Map over [xs] with at most [max] child effects running at once. Results
    are returned in input order and failures are fail-fast like {!for_each_par}.
    @raise Invalid_argument if [max <= 0]. *)

val uninterruptible : ('a, 'err) t -> ('a, 'err) t
(** Defer parent cancellation while running the wrapped effect.

    This maps to [Eio.Cancel.protect]. It does not turn interruption
    into a typed failure, and it does not catch defects. *)

val catch :
  ('err1 -> ('a, 'err2) t) -> ('a, 'err1) t -> ('a, 'err2) t

val tap_error : ('err -> unit) -> ('a, 'err) t -> ('a, 'err) t
(** Run an observer when the effect fails with a typed error, then rethrow the
    original typed failure. If the observer raises, the runtime reports a
    suppressed cause with the original [Cause.Fail] as [primary] and the
    observer exception as [finalizer], so diagnostics retain both failures. *)

val retry : Schedule.t -> ('err -> bool) -> ('a, 'err) t -> ('a, 'err) t

val delay : Duration.t -> ('a, 'err) t -> ('a, 'err) t
val timeout : Duration.t -> ('a, [> `Timeout ] as 'err) t -> ('a, 'err) t
val timeout_as :
  Duration.t -> on_timeout:'err -> ('a, 'err) t -> ('a, 'err) t
(** Like {!timeout}, but fails with [on_timeout] instead of widening the error
    row with raw Timeout. *)
val repeat : Schedule.t -> (unit, 'err) t -> (unit, 'err) t

val acquire_release :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'err) t) ->
  ('a, 'err) t
(** Acquire a resource and register [release] to run when the current runtime
    boundary, scope, supervisor scope, or daemon body exits. The release effect
    runs on success and on typed failure; release failures are reported as the
    run failure or suppressed onto the primary failure. *)

val scoped : ('a, 'err) t -> ('a, 'err) t

val with_background :
  ?name:string -> (unit, 'err) t -> (unit -> ('a, 'err) t) -> ('a, 'err) t
(** Run [background] while [use] executes, then cancel the background child when
    [use] returns or fails. This is the structured replacement for
    daemon-shaped application work that does not need to expose a child handle. *)

val supervisor_scoped :
  ?max_failures:int -> ('a, 'err) supervisor_body -> ('a, 'err) t

val with_error_renderer : ('err -> string) -> ('a, 'err) t -> ('a, 'err) t
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
(** Update a metric on the runtime's meter. *)

val here_attr : string * int * int * int -> ('a, 'err) t -> ('a, 'err) t
(** Attach a [loc] attribute using OCaml's native [__POS__] shape. *)

val fn :
  ?kind:Capabilities.span_kind ->
  ?error_renderer:('err -> string) ->
  string * int * int * int ->
  string ->
  ('a, 'err) t ->
  ('a, 'err) t
(** [fn __POS__ __FUNCTION__ body] names [body] after the current binding and
    records the source location as a [loc] span attribute. *)

val name : ('a, 'err) t -> string option
val collect_names : ('a, 'err) t -> string list
(** [collect_names effect] returns names that are statically present in
    [effect]'s current description.

    This is a preflight/documentation helper, not a complete runtime inventory.
    Continuation-producing nodes such as [bind], [catch], [for_each_par],
    [for_each_par_bounded], and [supervisor_scoped] are not forced or traversed,
    so names created by those continuations are intentionally absent. *)

val run : 'err Runtime_core.t -> ('a, 'err) t -> ('a, 'err) Exit.t
(** Run an effect to completion against a runtime. The wrapper-level pool
    overrides live on {!Runtime.run}. *)

module Private : sig
  (** Unstable extension hooks for Eta's runtime and sibling packages.

      This module intentionally does not expose the interpreter AST. External
      applications should prefer the public [Effect], [Runtime], [Pool], and
      [Resource] APIs unless a hook here is explicitly documented for their
      integration point. *)

  val daemon : (unit, 'err) t -> (unit, 'err) t
  (** Start an effect as a runtime-owned daemon. The daemon is joined/drained by
      [Runtime.run] finalizer handling; unchecked failures are runtime defects. *)

  val named_attrs :
    kind:Capabilities.span_kind ->
    string ->
    attrs:(string * string) list ->
    ('a, 'err) t ->
    ('a, 'err) t
  (** Attach a span name plus precomputed attributes. Used by internal resource
      helpers that already own their attribute set. *)

  val metric_updates :
    (string * string * string * Capabilities.metric_kind
    * (string * string) list
    * Capabilities.metric_value)
    list ->
    (unit, 'err) t
  (** Emit a prebatched set of metric updates. *)

  val metric_updates_lazy :
    (unit ->
    (string * string * string * Capabilities.metric_kind
    * (string * string) list
    * Capabilities.metric_value)
    list) ->
    (unit, 'err) t
  (** Lazily compute metric updates only when interpreted by a runtime with
      metrics enabled. *)

  val island_submit :
    ('input : immutable_data) ('output : immutable_data).
    string ->
    Island.pool ->
    ('input -> 'output) @ portable ->
    'input ->
    'output
  (** Runtime hook for executing a single island callback. *)

  val island_submit_map :
    ('input : immutable_data) ('output : immutable_data).
    string ->
    Island.pool ->
    ('input -> 'output) @ portable ->
    'input list ->
    'output list
  (** Runtime hook for executing a batch of island callbacks. *)

  val island_submit_map_result :
    ('input : immutable_data)
    ('output : immutable_data)
    ('error : immutable_data).
    string ->
    Island.pool ->
    ('input -> ('output, 'error) result) @ portable ->
    'input list ->
    ('output, 'error) result list
  (** Runtime hook for island callbacks that return typed per-item results. *)

  val island_submit_all_settled :
    ('input : immutable_data)
    ('output : immutable_data)
    ('error : immutable_data).
    Island.pool ->
    ('input -> ('output, 'error) result) @ portable ->
    'input list ->
    ('output, 'error) Island.settled list
  (** Runtime hook for island callbacks that keep worker crashes as per-item
      [Worker_died] results. *)

  type blocking_outcome =
    | Blocking_ok
    | Blocking_error of string
    | Blocking_cancelled
    | Blocking_rejected
    | Blocking_shutdown_rejected
    | Blocking_detached
  (** Blocking worker outcome used for runtime metrics. *)

  type blocking_event = {
    pool : string;
    name : string;
    queue_wait_ms : int;
    run_ms : int;
    outcome : blocking_outcome;
  }
  (** Blocking worker event emitted after queue/run completion. *)

  val blocking_default_config : Blocking.Pool.config
  (** Runtime default configuration for the implicit blocking pool. *)

  val blocking_submit :
    sw:Eio.Switch.t ->
    emit:(blocking_event -> unit) ->
    Blocking.Pool.t ->
    string ->
    ?on_cancel:(unit -> unit) ->
    (unit -> 'a) ->
    'a
  (** Runtime hook for submitting one blocking callback. *)

  val blocking_pool_name : Blocking.Pool.t -> string
  (** Runtime hook for diagnostic pool names. *)

  val in_blocking_worker : unit -> bool
  (** [true] while running inside an [Effect.Blocking] worker callback. *)

  val make_supervisor :
    sw:Eio.Switch.t -> max_failures:int option -> ('s, 'err) supervisor
  val supervisor_fork : ('s, 'err) supervisor -> (unit -> unit) -> unit
  val supervisor_max_failures : ('s, 'err) supervisor -> int option
  val supervisor_record_failure : ('s, 'err) supervisor -> 'err Cause.t -> unit
  val supervisor_failures : ('s, 'err) supervisor -> 'err Cause.t list
  val supervisor_failure_count : ('s, 'err) supervisor -> int
  val supervisor_register_child :
    ('s, 'err) supervisor -> (unit -> unit) -> unit
  val supervisor_cancel_children : ('s, 'err) supervisor -> unit
  val make_supervisor_child :
    promise:('a, 'err Cause.t) result Eio.Promise.t ->
    cancel:(unit -> unit) ->
    ('s, 'err, 'a) supervisor_child
  val supervisor_child_promise :
    ('s, 'err, 'a) supervisor_child -> ('a, 'err Cause.t) result Eio.Promise.t
  val supervisor_child_cancel : ('s, 'err, 'a) supervisor_child -> unit -> unit
  (** Runtime hooks for interpreting [supervisor_scoped]. *)
end
