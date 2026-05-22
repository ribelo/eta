type ('a, 'err) t =
  | Pure : 'a -> ('a, _) t
  | Fail : 'err -> (_, 'err) t
  | Thunk : string * (unit -> 'a) -> ('a, _) t
  | Bind : ('b, 'err) t * ('b -> ('a, 'err) t) -> ('a, 'err) t
  | Map : ('b, 'err) t * ('b -> 'a) -> ('a, 'err) t
  | Catch : ('a, 'err1) t * ('err1 -> ('a, 'err2) t) -> ('a, 'err2) t
  | Tap_error : ('a, 'err) t * ('err -> unit) -> ('a, 'err) t
  | Delay : Duration.t * ('a, 'err) t -> ('a, 'err) t
  | Timeout : Duration.t * ('a, [> `Timeout ] as 'err) t -> ('a, 'err) t
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
  | Named :
      Capabilities.span_kind * string * ('a, 'err) t -> ('a, 'err) t
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
}

and ('s, !'err, !'a) supervisor_child = {
  promise : ('a, 'err Cause.t) result Eio.Promise.t;
  cancel : unit -> unit;
}

let pure v = Pure v
let fail e = Fail e
let unit = Pure ()
let thunk name f = Thunk (name, f)
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

let with_error_renderer render e = Render_error (render, e)

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

let named_kind ?error_renderer ~kind name e =
  let named = Named (kind, name, e) in
  match error_renderer with
  | None -> named
  | Some render -> with_error_renderer render named

let named ?error_renderer name e =
  named_kind ?error_renderer ~kind:Capabilities.Internal name e
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
  match Trace_context.make ~trace_id ~span_id () with
  | Some ctx -> With_external_parent (ctx, e)
  | None -> invalid_arg "Effect.with_external_parent: invalid trace context"

let with_context ctx e = With_context (ctx, e)

let current_span = Current_span
let current_context = Current_context

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

let fn ?(kind = Capabilities.Internal) ?error_renderer pos name e =
  e |> here_attr pos |> named_kind ?error_renderer ~kind name

let rec name : type a err. (a, err) t -> string option = function
  | Render_error (_, e) -> name e
  | Named (_, n, _) -> Some n
  | Annotate (_, _, e) -> name e
  | _ -> None

let collect_names e =
  let rec walk : type a err. string list -> (a, err) t -> string list =
   fun acc -> function
    | Pure _ -> acc
    | Fail _ -> acc
    | Thunk (n, _) -> n :: acc
    | Render_error (_, e) -> walk acc e
    | Named (_, n, e) -> walk (n :: acc) e
    | Annotate (_, _, e) -> walk acc e
    | Link_span (_, e) -> walk acc e
    | With_external_parent (_, e) -> walk acc e
    | With_context (_, e) -> walk acc e
    | Current_span -> acc
    | Current_context -> acc
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
  type ('a, 'err) view = ('a, 'err) t =
    | Pure : 'a -> ('a, _) view
    | Fail : 'err -> (_, 'err) view
    | Thunk : string * (unit -> 'a) -> ('a, _) view
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

  (* [view] is a transparent alias of [t] with the constructors
     re-exposed for the runtime. The previous implementation reallocated
     an isomorphic GADT block per node visited (~3 minor words per
     [Bind] step). The [view] GADT is declared with constructors
     bit-identical to those of [t], so the runtime block layouts
     coincide; [%identity] tells the compiler to emit no conversion
     code, making [view] an exact zero-cost cast. *)
  external view : ('a, 'err) t -> ('a, 'err) view = "%identity"

  let daemon = daemon_internal

  let make_supervisor ~sw ~max_failures =
    {
      sw;
      max_failures;
      failures = Atomic.make [];
      failure_count = Atomic.make 0;
    }

  let supervisor_fork supervisor body = Eio.Fiber.fork ~sw:supervisor.sw body
  let supervisor_max_failures supervisor = supervisor.max_failures
  let supervisor_record_failure supervisor failure =
    let rec push () =
      let failures = Atomic.get supervisor.failures in
      if not (Atomic.compare_and_set supervisor.failures failures (failure :: failures))
      then push ()
    in
    push ();
    Atomic.incr supervisor.failure_count

  let supervisor_failures supervisor = Atomic.get supervisor.failures
  let supervisor_failure_count supervisor = Atomic.get supervisor.failure_count
  let make_supervisor_child ~promise ~cancel = { promise; cancel }
  let supervisor_child_promise child = child.promise
  let supervisor_child_cancel child = child.cancel
end
