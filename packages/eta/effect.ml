include Effect_ast

let pure v = Pure v
let fail e = Fail e
let unit = Pure ()
let sync f = Sync f
let island ?(name = "island") f input = Island { name; f; input }
let blocking ?pool ?(name = "blocking") f =
  Blocking_runtime.check_not_worker "Effect.blocking";
  Blocking { name; pool; f }
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
let timeout_as d ~on_timeout e = Timeout_as (d, on_timeout, e)
let repeat sch e = Repeat (e, sch)

let acquire_release ~acquire ~release = Acquire_release (acquire, release)
let scoped e = Scoped e
let supervisor_scoped ?max_failures body =
  Supervisor_scoped (max_failures, body)

let with_error_renderer render e = Render_error (render, e)
let suppress_observability e = Suppress_observability e

module Island = struct
  type worker_die = Island_runtime.worker_die = {
    kind : string;
    message : string;
    backtrace : string option;
  }

  type ('a : immutable_data, 'e : immutable_data) settled =
    ('a, 'e) Island_runtime.settled =
    | Ok of 'a
    | Error of 'e
    | Worker_died of worker_die

  type pool = Island_runtime.pool

  module Pool = Island_runtime.Pool

  let map ?(name = "island.map") ?pool ~f inputs =
    Island_map { name; pool; f; inputs }

  let map_result ?(name = "island.map_result") ?pool ~f inputs =
    Island_map_result { name; pool; f; inputs }

  let all_settled ?(name = "island.all_settled") ?pool ~f inputs =
    Island_all_settled { name; pool; f; inputs }
end

module Blocking = struct
  type ('a, 'err) effect = ('a, 'err) t

  let submit ?pool ?(name = "blocking") f =
    Blocking_runtime.check_not_worker "Effect.Blocking.submit";
    Blocking { name; pool; f }

  module Pool = struct
    include Blocking_runtime.Pool

    let shutdown pool = Blocking_shutdown pool
  end
end

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
  | Suppress_observability e -> name e
  | Named (_, n, _) -> Some n
  | Named_attrs (_, n, _, _) -> Some n
  | Annotate (_, _, e) -> name e
  | _ -> None

let collect_names e =
  let rec walk : type a err. string list -> (a, err) t -> string list =
   fun acc -> function
    | Pure _ -> acc
    | Fail _ -> acc
    | Sync _ -> acc
    | Island { name; _ }
    | Island_map { name; _ }
    | Island_map_result { name; _ }
    | Island_all_settled { name; _ } ->
        name :: acc
    | Blocking { name; _ } -> name :: acc
    | Blocking_shutdown _ -> acc
    | Render_error (_, e) -> walk acc e
    | Suppress_observability e -> walk acc e
    | Named (_, n, e) -> walk (n :: acc) e
    | Named_attrs (_, n, _, e) -> walk (n :: acc) e
    | Annotate (_, _, e) -> walk acc e
    | Link_span (_, e) -> walk acc e
    | With_external_parent (_, e) -> walk acc e
    | With_context (_, e) -> walk acc e
    | Current_span -> acc
    | Current_context -> acc
    | Log _ -> acc
    | Metric_update _ -> acc
    | Metric_updates _ -> acc
    | Metric_updates_lazy _ -> acc
    | Map (e, _) -> walk acc e
    | Delay (_, e) -> walk acc e
    | Timeout (_, e) -> walk acc e
    | Timeout_as (_, _, e) -> walk acc e
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
          pool : Island_runtime.pool option;
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
          pool : Island_runtime.pool option;
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
          pool : Island_runtime.pool option;
          f : ('input -> ('output, 'error) result) @@ portable;
          inputs : 'input list;
        }
        -> (('output, 'error) Island_runtime.settled list, 'err) view
    | Blocking : {
        name : string;
        pool : Blocking_runtime.t option;
        f : unit -> 'a;
      }
        -> ('a, 'err) view
    | Blocking_shutdown : Blocking_runtime.t -> (unit, 'err) view
    | Bind : ('b, 'err) t * ('b -> ('a, 'err) t) -> ('a, 'err) view
    | Map : ('b, 'err) t * ('b -> 'a) -> ('a, 'err) view
    | Catch :
        ('a, 'err1) t * ('err1 -> ('a, 'err2) t) -> ('a, 'err2) view
    | Tap_error : ('a, 'err) t * ('err -> unit) -> ('a, 'err) view
    | Delay : Duration.t * ('a, 'err) t -> ('a, 'err) view
    | Timeout :
        Duration.t * ('a, [> `Timeout ] as 'err) t -> ('a, 'err) view
    | Timeout_as : Duration.t * 'err * ('a, 'err) t -> ('a, 'err) view
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
    | Suppress_observability : ('a, 'err) t -> ('a, 'err) view
    | Named :
        Capabilities.span_kind * string * ('a, 'err) t -> ('a, 'err) view
    | Named_attrs :
        Capabilities.span_kind * string * (string * string) list * ('a, 'err) t
        -> ('a, 'err) view
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

  (* [view] is a transparent alias of [t] with the constructors
     re-exposed for the runtime. The previous implementation reallocated
     an isomorphic GADT block per node visited (~3 minor words per
     [Bind] step). The [view] GADT is declared with constructors
     bit-identical to those of [t], so the runtime block layouts
     coincide; [%identity] tells the compiler to emit no conversion
     code, making [view] an exact zero-cost cast. *)
  external view : ('a, 'err) t -> ('a, 'err) view = "%identity"

  let daemon = daemon_internal
  let named_attrs ~kind name ~attrs e = Named_attrs (kind, name, attrs, e)
  let metric_updates updates = Metric_updates updates
  let metric_updates_lazy make_updates = Metric_updates_lazy make_updates

  let island_submit = Island_runtime.submit
  let island_submit_map = Island_runtime.submit_map
  let island_submit_map_result = Island_runtime.submit_map_result
  let island_submit_all_settled = Island_runtime.submit_all_settled
  type blocking_outcome = Blocking_runtime.outcome =
    | Blocking_ok
    | Blocking_error of string
    | Blocking_cancelled
    | Blocking_rejected
    | Blocking_shutdown_rejected
    | Blocking_detached

  type blocking_event = Blocking_runtime.event = {
    pool : string;
    name : string;
    queue_wait_ms : int;
    run_ms : int;
    outcome : blocking_outcome;
  }

  let blocking_default_config = Blocking_runtime.default_config
  let blocking_submit = Blocking_runtime.submit
  let blocking_shutdown = Blocking_runtime.shutdown
  let blocking_pool_name = Blocking_runtime.name
  let in_blocking_worker = Blocking_runtime.in_worker

  let make_supervisor = Runtime_supervisor.make
  let supervisor_fork = Runtime_supervisor.fork
  let supervisor_max_failures = Runtime_supervisor.max_failures
  let supervisor_record_failure = Runtime_supervisor.record_failure
  let supervisor_failures = Runtime_supervisor.failures
  let supervisor_failure_count = Runtime_supervisor.failure_count
  let supervisor_register_child = Runtime_supervisor.register_child
  let supervisor_cancel_children = Runtime_supervisor.cancel_children
  let make_supervisor_child = Runtime_supervisor.make_child
  let supervisor_child_promise = Runtime_supervisor.child_promise
  let supervisor_child_cancel = Runtime_supervisor.child_cancel
end
