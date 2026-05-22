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
    concrete handles into functions that construct effects. Effet does not own a
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
      ('s, _, _) supervisor_child -> ('s, unit, _) supervisor_scope
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

val thunk : string -> (unit -> 'a) -> ('a, 'err) t
(** Same-domain lazy work. The callback runs in the interpreting Eio domain and
    may capture ordinary OCaml/Eio values. *)

val island :
  ('input : immutable_data) ('output : immutable_data).
  ?name:string ->
  ('input -> 'output) @ portable ->
  'input ->
  ('output, 'err) t
(** Portable twin of {!thunk} for one domain-offloaded callback.

    Anything accepted by [island] can also be expressed with {!thunk}; the
    reverse is deliberately false because [island] requires a [@ portable]
    callback and portable input/output values. The runtime must be configured
    with an island pool; Effet never silently falls back to same-domain
    execution. No timeout, cancellation, preemption, streaming/online queueing,
    portable AST, or portable Resource/Supervisor/Stream/OTel behavior is
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
  (** Reusable OxCaml [Parallel_scheduler] pool. Create it once, pass it to the
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

val retry : Schedule.t -> ('err -> bool) -> ('a, 'err) t -> ('a, 'err) t

val delay : Duration.t -> ('a, 'err) t -> ('a, 'err) t
val timeout : Duration.t -> ('a, [> `Timeout ] as 'err) t -> ('a, 'err) t
val repeat : Schedule.t -> (unit, 'err) t -> (unit, 'err) t

val acquire_release :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'err) t) ->
  ('a, 'err) t

val scoped : ('a, 'err) t -> ('a, 'err) t

val supervisor_scoped :
  ?max_failures:int -> ('a, 'err) supervisor_body -> ('a, 'err) t

val with_error_renderer : ('err -> string) -> ('a, 'err) t -> ('a, 'err) t
(** Render typed failures in observability span status and exception events for
    the wrapped effect. The renderer is scoped to this effect's error channel. *)

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
  ('s, 'err, 'a) supervisor_child -> ('s, unit, 'outer_err) supervisor_scope

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

module Private : sig
  type ('a, 'err) view =
    | Pure : 'a -> ('a, _) view
    | Fail : 'err -> (_, 'err) view
    | Thunk : string * (unit -> 'a) -> ('a, _) view
    | Island :
        ('input : immutable_data) ('output : immutable_data) 'err.
        {
          name : string;
          f : ('input -> 'output) @@ portable;
          input : 'input;
        }
        -> ('output, 'err) view
    | Island_map :
        ('input : immutable_data) ('output : immutable_data) 'err.
        {
          name : string;
          pool : Island.pool option;
          f : ('input -> 'output) @@ portable;
          inputs : 'input list;
        }
        -> ('output list, 'err) view
    | Island_map_result :
        ('input : immutable_data)
        ('output : immutable_data)
        ('error : immutable_data)
        'err.
        {
          name : string;
          pool : Island.pool option;
          f : ('input -> ('output, 'error) result) @@ portable;
          inputs : 'input list;
        }
        -> (('output, 'error) result list, 'err) view
    | Island_all_settled :
        ('input : immutable_data)
        ('output : immutable_data)
        ('error : immutable_data)
        'err.
        {
          name : string;
          pool : Island.pool option;
          f : ('input -> ('output, 'error) result) @@ portable;
          inputs : 'input list;
        }
        -> (('output, 'error) Island.settled list, 'err) view
    | Bind : ('b, 'err) t * ('b -> ('a, 'err) t) -> ('a, 'err) view
    | Map : ('b, 'err) t * ('b -> 'a) -> ('a, 'err) view
    | Catch :
        ('a, 'err1) t * ('err1 -> ('a, 'err2) t) -> ('a, 'err2) view
    | Tap_error : ('a, 'err) t * ('err -> unit) -> ('a, 'err) view
    | Delay : Duration.t * ('a, 'err) t -> ('a, 'err) view
    | Timeout :
        Duration.t * ('a, [> `Timeout ] as 'err) t -> ('a, 'err) view
    | Concat : (unit, 'err) t list -> (unit, 'err) view
    | Race : ('a, 'err) t list -> ('a, 'err) view
    | Par : ('a, 'err) t * ('b, 'err) t -> ('a * 'b, 'err) view
    | All : ('a, 'err) t list -> ('a list, 'err) view
    | All_settled :
        ('a, 'err) t list -> (('a, 'err Cause.t) result list, _) view
    | For_each_par : 'x list * ('x -> ('a, 'err) t) -> ('a list, 'err) view
    | For_each_par_bounded :
        int * 'x list * ('x -> ('a, 'err) t) -> ('a list, 'err) view
    | Daemon : (unit, 'err) t -> (unit, 'err) view
    | Uninterruptible : ('a, 'err) t -> ('a, 'err) view
    | Repeat : (unit, 'err) t * Schedule.t -> (unit, 'err) view
    | Retry : ('a, 'err) t * Schedule.t * ('err -> bool) -> ('a, 'err) view
    | Acquire_release :
        ('a, 'err) t * ('a -> (unit, 'err) t) -> ('a, 'err) view
    | Scoped : ('a, 'err) t -> ('a, 'err) view
    | Supervisor_scoped :
        int option * ('a, 'err) supervisor_body -> ('a, 'err) view
    | Render_error : ('err -> string) * ('a, 'err) t -> ('a, 'err) view
    | Named :
        Capabilities.span_kind * string * ('a, 'err) t -> ('a, 'err) view
    | Annotate : string * string * ('a, 'err) t -> ('a, 'err) view
    | Link_span : Capabilities.span_link * ('a, 'err) t -> ('a, 'err) view
    | With_external_parent :
        Capabilities.trace_context * ('a, 'err) t -> ('a, 'err) view
    | With_context :
        Capabilities.trace_context * ('a, 'err) t -> ('a, 'err) view
    | Current_span : (Capabilities.span_info option, 'err) view
    | Current_context : (Capabilities.trace_context option, 'err) view
    | Log :
        Capabilities.log_level * string * (string * string) list
        -> (unit, 'err) view
    | Metric_update : {
        name : string;
        description : string;
        unit_ : string;
        kind : Capabilities.metric_kind;
        attrs : (string * string) list;
        value : Capabilities.metric_value;
      }
        -> (unit, 'err) view

  val view : ('a, 'err) t -> ('a, 'err) view
  val daemon : (unit, 'err) t -> (unit, 'err) t

  val island_submit :
    ('input : immutable_data) ('output : immutable_data).
    string ->
    Island.pool ->
    ('input -> 'output) @ portable ->
    'input ->
    'output

  val island_submit_map :
    ('input : immutable_data) ('output : immutable_data).
    string ->
    Island.pool ->
    ('input -> 'output) @ portable ->
    'input list ->
    'output list

  val island_submit_map_result :
    ('input : immutable_data)
    ('output : immutable_data)
    ('error : immutable_data).
    string ->
    Island.pool ->
    ('input -> ('output, 'error) result) @ portable ->
    'input list ->
    ('output, 'error) result list

  val island_submit_all_settled :
    ('input : immutable_data)
    ('output : immutable_data)
    ('error : immutable_data).
    Island.pool ->
    ('input -> ('output, 'error) result) @ portable ->
    'input list ->
    ('output, 'error) Island.settled list

  val make_supervisor :
    sw:Eio.Switch.t -> max_failures:int option -> ('s, 'err) supervisor
  val supervisor_fork : ('s, 'err) supervisor -> (unit -> unit) -> unit
  val supervisor_max_failures : ('s, 'err) supervisor -> int option
  val supervisor_record_failure : ('s, 'err) supervisor -> 'err Cause.t -> unit
  val supervisor_failures : ('s, 'err) supervisor -> 'err Cause.t list
  val supervisor_failure_count : ('s, 'err) supervisor -> int
  val make_supervisor_child :
    promise:('a, 'err Cause.t) result Eio.Promise.t ->
    cancel:(unit -> unit) ->
    ('s, 'err, 'a) supervisor_child
  val supervisor_child_promise :
    ('s, 'err, 'a) supervisor_child -> ('a, 'err Cause.t) result Eio.Promise.t
  val supervisor_child_cancel : ('s, 'err, 'a) supervisor_child -> unit -> unit
end
