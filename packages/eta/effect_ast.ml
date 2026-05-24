type ('a, 'err) t =
  | Pure : 'a -> ('a, _) t
  | Fail : 'err -> (_, 'err) t
  | Sync : (unit -> 'a) -> ('a, _) t
  | Island :
      ('input : immutable_data) ('output : immutable_data) 'err.
      {
        name : string;
        f : ('input -> 'output) @@ portable;
        input : 'input;
      }
      -> ('output, 'err) t
  | Island_map :
      ('input : immutable_data) ('output : immutable_data) 'err.
      {
        name : string;
        pool : Island_runtime.pool option;
        f : ('input -> 'output) @@ portable;
        inputs : 'input list;
      }
      -> ('output list, 'err) t
  | Island_map_result :
      ('input : immutable_data)
      ('output : immutable_data)
      ('error : immutable_data)
      'err.
      {
        name : string;
        pool : Island_runtime.pool option;
        f : ('input -> ('output, 'error) result) @@ portable;
        inputs : 'input list;
      }
      -> (('output, 'error) result list, 'err) t
  | Island_all_settled :
      ('input : immutable_data)
      ('output : immutable_data)
      ('error : immutable_data)
      'err.
      {
        name : string;
        pool : Island_runtime.pool option;
        f : ('input -> ('output, 'error) result) @@ portable;
        inputs : 'input list;
      }
      -> (('output, 'error) Island_runtime.settled list, 'err) t
  | Blocking : {
      name : string;
      pool : Blocking_runtime.t option;
      f : unit -> 'a;
    }
      -> ('a, 'err) t
  | Bind : ('b, 'err) t * ('b -> ('a, 'err) t) -> ('a, 'err) t
  | Map : ('b, 'err) t * ('b -> 'a) -> ('a, 'err) t
  | Catch : ('a, 'err1) t * ('err1 -> ('a, 'err2) t) -> ('a, 'err2) t
  | Tap_error : ('a, 'err) t * ('err -> unit) -> ('a, 'err) t
  | Delay : Duration.t * ('a, 'err) t -> ('a, 'err) t
  | Timeout : Duration.t * ('a, [> `Timeout ] as 'err) t -> ('a, 'err) t
  | Timeout_as : Duration.t * 'err * ('a, 'err) t -> ('a, 'err) t
  | Concat : (unit, 'err) t list -> (unit, 'err) t
  | Race : ('a, 'err) t list -> ('a, 'err) t
  | Par : ('a, 'err) t * ('b, 'err) t -> ('a * 'b, 'err) t
  | All : ('a, 'err) t list -> ('a list, 'err) t
  | All_settled :
      ('a, 'err) t list -> (('a, 'err Cause.t) result list, _) t
  | For_each_par : 'x list * ('x -> ('a, 'err) t) -> ('a list, 'err) t
  | For_each_par_bounded :
      int * 'x list * ('x -> ('a, 'err) t) -> ('a list, 'err) t
  | Daemon : (unit, 'err) t -> (unit, 'err) t
  | Uninterruptible : ('a, 'err) t -> ('a, 'err) t
  | Repeat : (unit, 'err) t * Schedule.t -> (unit, 'err) t
  | Retry : ('a, 'err) t * Schedule.t * ('err -> bool) -> ('a, 'err) t
  | Acquire_release : ('a, 'err) t * ('a -> (unit, 'err) t) -> ('a, 'err) t
  | Scoped : ('a, 'err) t -> ('a, 'err) t
  | Supervisor_scoped :
      int option * ('a, 'err) supervisor_body -> ('a, 'err) t
  | Render_error : ('err -> string) * ('a, 'err) t -> ('a, 'err) t
  | Suppress_observability : ('a, 'err) t -> ('a, 'err) t
  | Named :
      Capabilities.span_kind * string * ('a, 'err) t -> ('a, 'err) t
  | Named_attrs :
      Capabilities.span_kind * string * (string * string) list * ('a, 'err) t
      -> ('a, 'err) t
  | Annotate : string * string * ('a, 'err) t -> ('a, 'err) t
  | Link_span : Capabilities.span_link * ('a, 'err) t -> ('a, 'err) t
  | With_external_parent :
      Capabilities.trace_context * ('a, 'err) t -> ('a, 'err) t
  | With_context :
      Capabilities.trace_context * ('a, 'err) t -> ('a, 'err) t
  | Current_span : (Capabilities.span_info option, 'err) t
  | Current_context : (Capabilities.trace_context option, 'err) t
  | Log :
      Capabilities.log_level * string * (string * string) list -> (unit, 'err) t
  | Metric_update : {
      name : string;
      description : string;
      unit_ : string;
      kind : Capabilities.metric_kind;
      attrs : (string * string) list;
      value : Capabilities.metric_value;
    }
      -> (unit, 'err) t
  | Metric_updates :
      (string * string * string * Capabilities.metric_kind
      * (string * string) list
      * Capabilities.metric_value)
      list
      -> (unit, 'err) t
  | Metric_updates_lazy :
      (unit ->
      (string * string * string * Capabilities.metric_kind
      * (string * string) list
      * Capabilities.metric_value)
      list)
      -> (unit, 'err) t

and ('s, 'a, 'err) supervisor_scope =
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

and ('s, !'err) supervisor = {
  sw : Eio.Switch.t;
  max_failures : int option;
  failures : 'err Cause.t list Atomic.t;
  failure_count : int Atomic.t;
  children : (unit -> unit) list Atomic.t;
}

and ('s, !'err, !'a) supervisor_child = {
  promise : ('a, 'err Cause.t) result Eio.Promise.t;
  cancel : unit -> unit;
}
