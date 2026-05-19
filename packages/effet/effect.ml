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
  | Daemon : ('env, 'err, unit) t -> ('env, 'err, unit) t
  | Uninterruptible : ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Repeat : ('env, 'err, unit) t * Schedule.t -> ('env, 'err, unit) t
  | Retry :
      ('env, 'err, 'a) t * Schedule.t * ('err -> bool)
      -> ('env, 'err, 'a) t
  | Acquire_release :
      ('env, 'err, 'a) t * ('a -> ('env, 'err, unit) t)
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

and ('s, !'err) supervisor = {
  sw : Eio.Switch.t;
  max_failures : int option;
  failures : 'err Cause.t list ref;
}

and ('s, !'err, !'a) supervisor_child = {
  promise : ('a, 'err Cause.t) result Eio.Promise.t;
  cancel : unit -> unit;
}

let pure v = Pure v
let fail e = Fail e
let unit = Pure ()
let sync name f = Sync (name, f)
let async name f = Async (name, f)

let map f e = Map (e, f)
let bind k e = Bind (e, k)
let ( >>= ) e k = Bind (e, k)
let tap k e = Bind (e, fun a -> Map (k a, fun () -> a))
let seq next self = Concat [ self; next ]
let concat es = Concat es
let race es = Race es
let par a b = Par (a, b)
let all xs = All xs
let all_settled xs = All_settled xs
let for_each_par xs f = For_each_par (xs, f)
let for_each_par_bounded ~max xs f =
  if max <= 0 then invalid_arg "Effect.for_each_par_bounded: max must be > 0";
  For_each_par_bounded (max, xs, f)
let uninterruptible e = Uninterruptible e

let catch h e = Catch (e, h)
let tap_error f e = Tap_error (e, f)
let retry sch pred e = Retry (e, sch, pred)

let delay d e = Delay (d, e)
let timeout d e = Timeout (d, e)
let repeat sch e = Repeat (e, sch)

let acquire_release ~acquire ~release = Acquire_release (acquire, release)
let scoped e = Scoped e
let supervisor_scoped ?max_failures body =
  Supervisor_scoped (max_failures, body)

let supervisor_pure v = Supervisor_pure v
let supervisor_lift e = Supervisor_lift e
let supervisor_fail e = Supervisor_fail e
let supervisor_bind k e = Supervisor_bind (e, k)
let supervisor_start supervisor e = Supervisor_start (supervisor, e)
let supervisor_await child = Supervisor_await child
let supervisor_cancel child = Supervisor_cancel child
let supervisor_failures supervisor = Supervisor_failures supervisor
let supervisor_check supervisor = Supervisor_check supervisor
let supervisor_yield = Supervisor_yield

let named_kind ~kind name e = Named (kind, name, e)
let named name e = named_kind ~kind:Capabilities.Internal name e
let annotate ~key ~value e = Annotate (key, value, e)
let link_span ?(attrs = []) ~trace_id ~span_id e =
  Link_span
    ( {
        Capabilities.link_trace_id = trace_id;
        link_span_id = span_id;
        link_attrs = attrs;
      },
      e )

let with_external_parent ~trace_id ~span_id e =
  With_external_parent (trace_id, span_id, e)

let current_span = Current_span

let log ?(level = Capabilities.Info) ?(attrs = []) body =
  Log (level, body, attrs)

let metric_update ?(description = "") ?(unit_ = "") ?(attrs = []) ~name
    ~kind value =
  Metric_update { name; description; unit_; kind; attrs; value }
let here_attr (file, line, col_start, col_end) e =
  Annotate
    ( "loc",
      Printf.sprintf "%s:%d:%d-%d" file line col_start col_end,
      e )

let fn ?(kind = Capabilities.Internal) pos name e =
  e |> here_attr pos |> named_kind ~kind name

let rec name : type env err a. (env, err, a) t -> string option = function
  | Named (_, n, _) -> Some n
  | Annotate (_, _, e) -> name e
  | _ -> None

let collect_names e =
  let rec walk : type env err a.
      string list -> (env, err, a) t -> string list =
   fun acc -> function
    | Pure _ -> acc
    | Fail _ -> acc
    | Sync (n, _) -> n :: acc
    | Async (n, _) -> n :: acc
    | Named (_, n, e) -> walk (n :: acc) e
    | Annotate (_, _, e) -> walk acc e
    | Link_span (_, e) -> walk acc e
    | With_external_parent (_, _, e) -> walk acc e
    | Current_span -> acc
    | Log _ -> acc
    | Metric_update _ -> acc
    | Map (e, _) -> walk acc e
    | Delay (_, e) -> walk acc e
    | Timeout (_, e) -> walk acc e
    | Tap_error (e, _) -> walk acc e
    | Repeat (e, _) -> walk acc e
    | Retry (e, _, _) -> walk acc e
    | Scoped e -> walk acc e
    | Supervisor_scoped _ -> acc
    | Acquire_release (acq, _) -> walk acc acq
    | Bind (e, _) -> walk acc e
    | Catch (e, _) -> walk acc e
    | Concat xs -> List.fold_left walk acc xs
    | Race xs -> List.fold_left walk acc xs
    | Par (a, b) -> walk (walk acc a) b
    | All xs -> List.fold_left walk acc xs
    | All_settled xs -> List.fold_left walk acc xs
    | For_each_par _ -> acc
    | For_each_par_bounded _ -> acc
    | Daemon e -> walk acc e
    | Uninterruptible e -> walk acc e
  in
  List.rev (walk [] e)

let daemon_internal eff = Daemon eff

module Private = struct
  type ('env, 'err, 'a) view =
    | Pure : 'a -> (_, _, 'a) view
    | Fail : 'err -> (_, 'err, _) view
    | Sync : string * ('env -> 'a) -> ('env, _, 'a) view
    | Async : string * ('env -> 'a) -> ('env, _, 'a) view
    | Bind :
        ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t)
        -> ('env, 'err, 'a) view
    | Map : ('env, 'err, 'b) t * ('b -> 'a) -> ('env, 'err, 'a) view
    | Catch :
        ('env, 'err1, 'a) t * ('err1 -> ('env, 'err2, 'a) t)
        -> ('env, 'err2, 'a) view
    | Tap_error : ('env, 'err, 'a) t * ('err -> unit) -> ('env, 'err, 'a) view
    | Delay : Duration.t * ('env, 'err, 'a) t -> ('env, 'err, 'a) view
    | Timeout :
        Duration.t * ('env, 'err, 'a) t
        -> ('env, [> `Timeout ] as 'err, 'a) view
    | Concat : ('env, 'err, unit) t list -> ('env, 'err, unit) view
    | Race : ('env, 'err, 'a) t list -> ('env, 'err, 'a) view
    | Par :
        ('env, 'err, 'a) t * ('env, 'err, 'b) t
        -> ('env, 'err, 'a * 'b) view
    | All : ('env, 'err, 'a) t list -> ('env, 'err, 'a list) view
    | All_settled :
        ('env, 'err, 'a) t list
        -> ('env, _, ('a, 'err Cause.t) result list) view
    | For_each_par :
        'x list * ('x -> ('env, 'err, 'a) t)
        -> ('env, 'err, 'a list) view
    | For_each_par_bounded :
        int * 'x list * ('x -> ('env, 'err, 'a) t)
        -> ('env, 'err, 'a list) view
    | Daemon : ('env, 'err, unit) t -> ('env, 'err, unit) view
    | Uninterruptible : ('env, 'err, 'a) t -> ('env, 'err, 'a) view
    | Repeat : ('env, 'err, unit) t * Schedule.t -> ('env, 'err, unit) view
    | Retry :
        ('env, 'err, 'a) t * Schedule.t * ('err -> bool)
        -> ('env, 'err, 'a) view
    | Acquire_release :
        ('env, 'err, 'a) t * ('a -> ('env, _, unit) t)
        -> ('env, 'err, 'a) view
    | Scoped : ('env, 'err, 'a) t -> ('env, 'err, 'a) view
    | Supervisor_scoped :
        int option * ('env, 'err, 'a) supervisor_body
        -> ('env, 'err, 'a) view
    | Named :
        Capabilities.span_kind * string * ('env, 'err, 'a) t
        -> ('env, 'err, 'a) view
    | Annotate : string * string * ('env, 'err, 'a) t -> ('env, 'err, 'a) view
    | Link_span :
        Capabilities.span_link * ('env, 'err, 'a) t -> ('env, 'err, 'a) view
    | With_external_parent :
        string * string * ('env, 'err, 'a) t -> ('env, 'err, 'a) view
    | Current_span : ('env, 'err, Capabilities.span_info option) view
    | Log :
        Capabilities.log_level * string * (string * string) list
        -> ('env, 'err, unit) view
    | Metric_update : {
        name : string;
        description : string;
        unit_ : string;
        kind : Capabilities.metric_kind;
        attrs : (string * string) list;
        value : Capabilities.metric_value;
      }
        -> ('env, 'err, unit) view

  let view : type env err a. (env, err, a) t -> (env, err, a) view = function
    | Pure value -> Pure value
    | Fail err -> Fail err
    | Sync (name, f) -> Sync (name, f)
    | Async (name, f) -> Async (name, f)
    | Bind (eff, k) -> Bind (eff, k)
    | Map (eff, f) -> Map (eff, f)
    | Catch (eff, handler) -> Catch (eff, handler)
    | Tap_error (eff, observe) -> Tap_error (eff, observe)
    | Delay (duration, eff) -> Delay (duration, eff)
    | Timeout (duration, eff) -> Timeout (duration, eff)
    | Concat children -> Concat children
    | Race children -> Race children
    | Par (left, right) -> Par (left, right)
    | All children -> All children
    | All_settled children -> All_settled children
    | For_each_par (xs, f) -> For_each_par (xs, f)
    | For_each_par_bounded (max, xs, f) -> For_each_par_bounded (max, xs, f)
    | Daemon eff -> Daemon eff
    | Uninterruptible eff -> Uninterruptible eff
    | Repeat (eff, schedule) -> Repeat (eff, schedule)
    | Retry (eff, schedule, predicate) -> Retry (eff, schedule, predicate)
    | Acquire_release (acquire, release) -> Acquire_release (acquire, release)
    | Scoped eff -> Scoped eff
    | Supervisor_scoped (max_failures, body) ->
        Supervisor_scoped (max_failures, body)
    | Named (kind, name, eff) -> Named (kind, name, eff)
    | Annotate (key, value, eff) -> Annotate (key, value, eff)
    | Link_span (link, eff) -> Link_span (link, eff)
    | With_external_parent (trace_id, span_id, eff) ->
        With_external_parent (trace_id, span_id, eff)
    | Current_span -> Current_span
    | Log (level, body, attrs) -> Log (level, body, attrs)
    | Metric_update { name; description; unit_; kind; attrs; value } ->
        Metric_update { name; description; unit_; kind; attrs; value }

  let daemon = daemon_internal

  let make_supervisor ~sw ~max_failures = { sw; max_failures; failures = ref [] }
  let supervisor_switch supervisor = supervisor.sw
  let supervisor_max_failures supervisor = supervisor.max_failures
  let supervisor_failures_ref supervisor = supervisor.failures
  let make_supervisor_child ~promise ~cancel = { promise; cancel }
  let supervisor_child_promise child = child.promise
  let supervisor_child_cancel child = child.cancel
end
