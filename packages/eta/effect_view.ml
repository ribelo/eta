type ('a, 'err) view =
  | Pure : 'a -> ('a, _) view
  | Fail : 'err -> (_, 'err) view
  | Sync : (unit -> 'a) -> ('a, _) view
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
        pool : Effect.Island.pool option;
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
        pool : Effect.Island.pool option;
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
        pool : Effect.Island.pool option;
        f : ('input -> ('output, 'error) result) @@ portable;
        inputs : 'input list;
      }
      -> (('output, 'error) Effect.Island.settled list, 'err) view
  | Blocking : {
      name : string;
      pool : Effect.Blocking.Pool.t option;
      f : unit -> 'a;
    }
      -> ('a, 'err) view
  | Blocking_shutdown : Effect.Blocking.Pool.t -> (unit, 'err) view
  | Bind :
      ('b, 'err) Effect.t * ('b -> ('a, 'err) Effect.t) -> ('a, 'err) view
  | Map : ('b, 'err) Effect.t * ('b -> 'a) -> ('a, 'err) view
  | Catch :
      ('a, 'err1) Effect.t * ('err1 -> ('a, 'err2) Effect.t)
      -> ('a, 'err2) view
  | Tap_error : ('a, 'err) Effect.t * ('err -> unit) -> ('a, 'err) view
  | Delay : Duration.t * ('a, 'err) Effect.t -> ('a, 'err) view
  | Timeout :
      Duration.t * ('a, [> `Timeout ] as 'err) Effect.t -> ('a, 'err) view
  | Timeout_as :
      Duration.t * 'err * ('a, 'err) Effect.t -> ('a, 'err) view
  | Concat : (unit, 'err) Effect.t list -> (unit, 'err) view
  | Race : ('a, 'err) Effect.t list -> ('a, 'err) view
  | Par :
      ('a, 'err) Effect.t * ('b, 'err) Effect.t -> ('a * 'b, 'err) view
  | All : ('a, 'err) Effect.t list -> ('a list, 'err) view
  | All_settled :
      ('a, 'err) Effect.t list -> (('a, 'err Cause.t) result list, _) view
  | For_each_par :
      'x list * ('x -> ('a, 'err) Effect.t) -> ('a list, 'err) view
  | For_each_par_bounded :
      int * 'x list * ('x -> ('a, 'err) Effect.t) -> ('a list, 'err) view
  | Daemon : (unit, 'err) Effect.t -> (unit, 'err) view
  | Uninterruptible : ('a, 'err) Effect.t -> ('a, 'err) view
  | Repeat : (unit, 'err) Effect.t * Schedule.t -> (unit, 'err) view
  | Retry :
      ('a, 'err) Effect.t * Schedule.t * ('err -> bool) -> ('a, 'err) view
  | Acquire_release :
      ('a, 'err) Effect.t * ('a -> (unit, 'err) Effect.t) -> ('a, 'err) view
  | Scoped : ('a, 'err) Effect.t -> ('a, 'err) view
  | Supervisor_scoped :
      int option * ('a, 'err) Effect.supervisor_body -> ('a, 'err) view
  | Render_error : ('err -> string) * ('a, 'err) Effect.t -> ('a, 'err) view
  | Suppress_observability : ('a, 'err) Effect.t -> ('a, 'err) view
  | Named :
      Capabilities.span_kind * string * ('a, 'err) Effect.t -> ('a, 'err) view
  | Named_attrs :
      Capabilities.span_kind
      * string
      * (string * string) list
      * ('a, 'err) Effect.t
      -> ('a, 'err) view
  | Annotate : string * string * ('a, 'err) Effect.t -> ('a, 'err) view
  | Link_span : Capabilities.span_link * ('a, 'err) Effect.t -> ('a, 'err) view
  | With_external_parent :
      Capabilities.trace_context * ('a, 'err) Effect.t -> ('a, 'err) view
  | With_context :
      Capabilities.trace_context * ('a, 'err) Effect.t -> ('a, 'err) view
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
  | Metric_updates :
      (string * string * string * Capabilities.metric_kind
      * (string * string) list
      * Capabilities.metric_value)
      list
      -> (unit, 'err) view
  | Metric_updates_lazy :
      (unit ->
      (string * string * string * Capabilities.metric_kind
      * (string * string) list
      * Capabilities.metric_value)
      list)
      -> (unit, 'err) view

external view : ('a, 'err) Effect.t -> ('a, 'err) view = "%identity"
