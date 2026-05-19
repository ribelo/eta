(** Lazy, runtime-interpreted effects.

    {v
      ('env, 'err, 'a) Effect.t
        ^^^^   ^^^   ^^
        env    err   success
    v}

    - ['env] is the requirement channel. Prefer structural object types
      for capabilities, e.g. [< clock : Capabilities.clock; .. >].
    - ['err] is the typed failure channel. Polymorphic variants work well:
      [[> `Http_404 | `Db_unavailable ]].
    - ['a] is the success value.

    Effet follows the Effect-TS / ZIO shape, but uses OCaml's GADTs,
    polymorphic variants, object rows, and Eio runtime primitives. *)

type ('env, 'err, 'a) t =
  | Pure : 'a -> (_, _, 'a) t
  | Fail : 'err -> (_, 'err, _) t
  | Sync : string * ('env -> 'a) -> ('env, _, 'a) t
  | Async : string * ('env -> 'a) -> ('env, _, 'a) t
  | Bind :
      ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t)
      -> ('env, 'err, 'a) t
  | Map : ('env, 'err, 'b) t * ('b -> 'a) -> ('env, 'err, 'a) t
  | Catch :
      ('env, 'err1, 'a) t * ('err1 -> ('env, 'err2, 'a) t)
      -> ('env, 'err2, 'a) t
  | Tap_error : ('env, 'err, 'a) t * ('err -> unit) -> ('env, 'err, 'a) t
  | Delay : Duration.t * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Timeout :
      Duration.t * ('env, 'err, 'a) t -> ('env, [> `Timeout ] as 'err, 'a) t
  | Concat : ('env, 'err, unit) t list -> ('env, 'err, unit) t
  | Race : ('env, 'err, 'a) t list -> ('env, 'err, 'a) t
  | Par :
      ('env, 'err, 'a) t * ('env, 'err, 'b) t
      -> ('env, 'err, 'a * 'b) t
  | All : ('env, 'err, 'a) t list -> ('env, 'err, 'a list) t
  | All_settled :
      ('env, 'err, 'a) t list
      -> ('env, _, ('a, 'err Cause.t) result list) t
  | For_each_par :
      'x list * ('x -> ('env, 'err, 'a) t)
      -> ('env, 'err, 'a list) t
  | For_each_par_bounded :
      int * 'x list * ('x -> ('env, 'err, 'a) t)
      -> ('env, 'err, 'a list) t
  | Detach : ('env, _, unit) t -> ('env, 'err, unit) t
  | Uninterruptible : ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Repeat : ('env, 'err, unit) t * Schedule.t -> ('env, 'err, unit) t
  | Retry :
      ('env, 'err, 'a) t * Schedule.t * ('err -> bool)
      -> ('env, 'err, 'a) t
  | Acquire_release :
      ('env, 'err, 'a) t * ('a -> ('env, _, unit) t)
      -> ('env, 'err, 'a) t
  | Scoped : ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Supervisor_scoped :
      int option * ('env, 'err, 'a) supervisor_body
      -> ('env, 'err, 'a) t
  | Named :
      Capabilities.span_kind * string * ('env, 'err, 'a) t
      -> ('env, 'err, 'a) t
  | Annotate : string * string * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Link_span :
      Capabilities.span_link * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | With_external_parent :
      string * string * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Current_span : ('env, 'err, Capabilities.span_info option) t
  | Log :
      Capabilities.log_level * string * (string * string) list
      -> ('env, 'err, unit) t
  | Metric_update : {
      name : string;
      description : string;
      unit_ : string;
      kind : Capabilities.metric_kind;
      attrs : (string * string) list;
      value : Capabilities.metric_value;
    }
      -> ('env, 'err, unit) t
  | Provide :
      'env_in * ('env_in, 'err, 'a) t -> ('env_out, 'err, 'a) t

and ('s, 'env, 'err, 'a) supervisor_scope =
  | Supervisor_pure : 'a -> (_, _, _, 'a) supervisor_scope
  | Supervisor_lift :
      ('env, 'err, 'a) t -> (_, 'env, 'err, 'a) supervisor_scope
  | Supervisor_fail : 'err -> (_, _, 'err, _) supervisor_scope
  | Supervisor_bind :
      ('s, 'env, 'err, 'b) supervisor_scope
      * ('b -> ('s, 'env, 'err, 'a) supervisor_scope)
      -> ('s, 'env, 'err, 'a) supervisor_scope
  | Supervisor_start :
      ('s, 'err) supervisor
      * ('s, 'env, 'err, 'a) supervisor_scope
      -> ('s, 'env, _, ('s, 'err, 'a) supervisor_child) supervisor_scope
  | Supervisor_await :
      ('s, 'err, 'a) supervisor_child -> ('s, _, 'err, 'a) supervisor_scope
  | Supervisor_cancel :
      ('s, _, _) supervisor_child -> ('s, _, _, unit) supervisor_scope
  | Supervisor_failures :
      ('s, 'err) supervisor -> ('s, _, _, 'err Cause.t list) supervisor_scope
  | Supervisor_check :
      ('s, [> `Supervisor_failed of int ] as 'err) supervisor
      -> ('s, _, 'err, unit) supervisor_scope
  | Supervisor_yield : ('s, _, _, unit) supervisor_scope

and ('env, 'err, 'a) supervisor_body = {
  run :
    's.
    ('s, 'err) supervisor -> ('s, 'env, 'err, 'a) supervisor_scope;
}

and ('s, !'err) supervisor
and ('s, !'err, !'a) supervisor_child

val pure : 'a -> ('env, 'err, 'a) t
val fail : 'err -> ('env, 'err, 'a) t
val unit : ('env, 'err, unit) t

val sync : string -> ('env -> 'a) -> ('env, 'err, 'a) t
val async : string -> ('env -> 'a) -> ('env, 'err, 'a) t

val map : ('a -> 'b) -> ('env, 'err, 'a) t -> ('env, 'err, 'b) t
val bind :
  ('a -> ('env, 'err, 'b) t) -> ('env, 'err, 'a) t -> ('env, 'err, 'b) t
val ( >>= ) :
  ('env, 'err, 'a) t -> ('a -> ('env, 'err, 'b) t) -> ('env, 'err, 'b) t

val tap :
  ('a -> ('env, 'err, unit) t) -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t

val seq : ('env, 'err, unit) t -> ('env, 'err, unit) t -> ('env, 'err, unit) t
val concat : ('env, 'err, unit) t list -> ('env, 'err, unit) t

val race : ('env, 'err, 'a) t list -> ('env, 'err, 'a) t
(** First child to produce a value wins; the rest are cancelled. *)

val par :
  ('env, 'err, 'a) t -> ('env, 'err, 'b) t -> ('env, 'err, 'a * 'b) t
(** Run two effects concurrently; collect both successes as a pair.
    Fail-fast: the first child failure cancels the sibling and the
    cause propagates upward. *)

val all : ('env, 'err, 'a) t list -> ('env, 'err, 'a list) t
(** Run effects concurrently, collecting results in input order.
    Fail-fast: the first child failure cancels the others; the cause
    of the first observed failure propagates. *)

val all_settled :
  ('env, 'err, 'a) t list -> ('env, _, ('a, 'err Cause.t) result list) t
(** Run effects concurrently and collect every child outcome in input order.
    Child failures are returned as [Error cause] values instead of failing the
    outer effect. *)

val for_each_par :
  'x list -> ('x -> ('env, 'err, 'a) t) -> ('env, 'err, 'a list) t
(** Map over [xs] concurrently with [f]; collect results in input
    order. Fail-fast like {!all}. *)

val for_each_par_bounded :
  max:int ->
  'x list ->
  ('x -> ('env, 'err, 'a) t) ->
  ('env, 'err, 'a list) t
(** Map over [xs] with at most [max] child effects running at once. Results
    are returned in input order and failures are fail-fast like {!for_each_par}.
    @raise Invalid_argument if [max <= 0]. *)

val detach : ('env, _, unit) t -> ('env, 'err, unit) t
(** Start a unit effect detached from the current effect and return
    immediately. The runtime owns the detached fiber. *)

val uninterruptible : ('env, 'err, 'a) t -> ('env, 'err, 'a) t
(** Defer parent cancellation while running the wrapped effect.

    This maps to [Eio.Cancel.protect]. It does not turn interruption
    into a typed failure, and it does not catch defects. *)

val catch :
  ('err1 -> ('env, 'err2, 'a) t) ->
  ('env, 'err1, 'a) t ->
  ('env, 'err2, 'a) t

val tap_error :
  ('err -> unit) -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t

val retry :
  Schedule.t -> ('err -> bool) -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t

val delay : Duration.t -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
val timeout :
  Duration.t -> ('env, [> `Timeout ] as 'err, 'a) t -> ('env, 'err, 'a) t
val repeat : Schedule.t -> ('env, 'err, unit) t -> ('env, 'err, unit) t

val acquire_release :
  acquire:('env, 'err, 'a) t ->
  release:('a -> ('env, _, unit) t) ->
  ('env, 'err, 'a) t

val scoped : ('env, 'err, 'a) t -> ('env, 'err, 'a) t

val supervisor_scoped :
  ?max_failures:int ->
  ('env, 'err, 'a) supervisor_body ->
  ('env, 'err, 'a) t

val supervisor_pure : 'a -> ('s, 'env, 'err, 'a) supervisor_scope

val supervisor_lift :
  ('env, 'err, 'a) t -> ('s, 'env, 'err, 'a) supervisor_scope

val supervisor_fail : 'err -> ('s, 'env, 'err, 'a) supervisor_scope

val supervisor_bind :
  ('a -> ('s, 'env, 'err, 'b) supervisor_scope) ->
  ('s, 'env, 'err, 'a) supervisor_scope ->
  ('s, 'env, 'err, 'b) supervisor_scope

val supervisor_start :
  ('s, 'err) supervisor ->
  ('s, 'env, 'err, 'a) supervisor_scope ->
  ('s, 'env, 'outer_err, ('s, 'err, 'a) supervisor_child) supervisor_scope

val supervisor_await :
  ('s, 'err, 'a) supervisor_child -> ('s, 'env, 'err, 'a) supervisor_scope

val supervisor_cancel :
  ('s, 'err, 'a) supervisor_child -> ('s, 'env, 'outer_err, unit) supervisor_scope

val supervisor_failures :
  ('s, 'err) supervisor -> ('s, 'env, 'outer_err, 'err Cause.t list) supervisor_scope

val supervisor_check :
  ('s, [> `Supervisor_failed of int ] as 'err) supervisor ->
  ('s, 'env, 'err, unit) supervisor_scope

val supervisor_yield : ('s, 'env, 'err, unit) supervisor_scope

val provide : 'env_in -> ('env_in, 'err, 'a) t -> ('env_out, 'err, 'a) t
(** Run [e] under a fully-replaced environment.

    The outer env is unconstrained: nothing of it reaches [e]. Useful
    for test isolation, sub-system sandboxing, and any case where a
    sub-effect should observe a different capability bundle than the
    rest of the program. *)

val named : string -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
val named_kind :
  kind:Capabilities.span_kind ->
  string ->
  ('env, 'err, 'a) t ->
  ('env, 'err, 'a) t
val annotate :
  key:string -> value:string -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t

val link_span :
  ?attrs:(string * string) list ->
  trace_id:string ->
  span_id:string ->
  ('env, 'err, 'a) t ->
  ('env, 'err, 'a) t
(** Attach a {!Capabilities.span_link} to the span opened by [body]. If [body]
    has no enclosing {!named} span, the link buffers and attaches to the next
    one (mirrors the buffered-attribute semantics). *)

val with_external_parent :
  trace_id:string ->
  span_id:string ->
  ('env, 'err, 'a) t ->
  ('env, 'err, 'a) t
(** Run [body] with the next opened {!named} span using the given OTLP
    trace context as its parent. Useful when the caller already received a
    parent span context out-of-band (e.g. a W3C [traceparent] header). *)

val current_span :
  ('env, 'err, Capabilities.span_info option) t
(** Yield the {!Capabilities.span_info} of the currently active span on this
    fiber, or [None] if none is open. *)

val log :
  ?level:Capabilities.log_level ->
  ?attrs:(string * string) list ->
  string ->
  ('env, 'err, unit) t
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
  ('env, 'err, unit) t
(** Update a metric on the runtime's meter. *)

val here_attr :
  string * int * int * int -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
(** Attach a [loc] attribute using OCaml's native [__POS__] shape. *)

val fn :
  ?kind:Capabilities.span_kind ->
  string * int * int * int ->
  string ->
  ('env, 'err, 'a) t ->
  ('env, 'err, 'a) t
(** [fn __POS__ __FUNCTION__ body] names [body] after the current binding and
    records the source location as a [loc] span attribute. *)

val name : ('env, 'err, 'a) t -> string option
val collect_names : ('env, 'err, 'a) t -> string list

module Private : sig
  val make_supervisor :
    sw:Eio.Switch.t ->
    max_failures:int option ->
    ('s, 'err) supervisor

  val supervisor_switch : ('s, 'err) supervisor -> Eio.Switch.t
  val supervisor_max_failures : ('s, 'err) supervisor -> int option
  val supervisor_failures_ref : ('s, 'err) supervisor -> 'err Cause.t list ref

  val make_supervisor_child :
    promise:('a, 'err Cause.t) result Eio.Promise.t ->
    cancel:(unit -> unit) ->
    ('s, 'err, 'a) supervisor_child

  val supervisor_child_promise :
    ('s, 'err, 'a) supervisor_child ->
    ('a, 'err Cause.t) result Eio.Promise.t

  val supervisor_child_cancel : ('s, 'err, 'a) supervisor_child -> unit -> unit
end
