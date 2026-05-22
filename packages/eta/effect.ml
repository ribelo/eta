module Island_runtime = struct
  type worker_die : immutable_data = {
    kind : string;
    message : string;
    backtrace : string option;
  }

  type ('a : immutable_data, 'e : immutable_data) settled : immutable_data =
    | Ok of 'a
    | Error of 'e
    | Worker_died of worker_die

  type pool = {
    scheduler : Parallel_scheduler.t;
    mutable stopped : bool;
  }

  type ('a : immutable_data) map_outcome : immutable_data =
    | Map_ok of 'a
    | Map_worker_died of worker_die

  type ('a : immutable_data, 'e : immutable_data) result_outcome :
    immutable_data =
    | Result_ok of 'a
    | Result_error of 'e
    | Result_worker_died of worker_die

  let generic_worker_die =
    {
      kind = "worker_died";
      message = "portable island callback raised";
      backtrace = None;
    }

  let raise_worker_die name die =
    failwith
      (Printf.sprintf "%s: worker died (%s): %s" name die.kind die.message)

  module Pool = struct
    type t = pool

    let create ?(domains = 2) () =
      if domains <= 0 then
        invalid_arg "Effect.Island.Pool.create: domains must be > 0";
      {
        scheduler = Parallel_scheduler.create ~max_domains:domains ();
        stopped = false;
      }

    let shutdown pool =
      if not pool.stopped then (
        pool.stopped <- true;
        Parallel_scheduler.stop pool.scheduler)
  end

  let ensure_running pool =
    if pool.stopped then invalid_arg "Effect.Island: pool already shut down"

  let (capture_map @ portable) (f @ portable) input =
    try Map_ok (f input) with _ -> Map_worker_died generic_worker_die

  let (capture_result @ portable) (f @ portable) input =
    try
      match f input with
      | Stdlib.Ok value -> Result_ok value
      | Stdlib.Error error -> Result_error error
    with _ -> Result_worker_died generic_worker_die

  let rec map_outcomes_with_parallel parallel (f @ portable) = function
    | [] -> []
    | [ x ] ->
        let #(result, ()) =
          Parallel.fork_join2 parallel
            (fun _ -> capture_map f x)
            (fun _ -> ())
        in
        [ result ]
    | left :: right :: rest ->
        let #(left, right) =
          Parallel.fork_join2 parallel
            (fun _ -> capture_map f left)
            (fun _ -> capture_map f right)
        in
        left :: right :: map_outcomes_with_parallel parallel f rest

  let rec result_outcomes_with_parallel parallel (f @ portable) = function
    | [] -> []
    | [ x ] ->
        let #(result, ()) =
          Parallel.fork_join2 parallel
            (fun _ -> capture_result f x)
            (fun _ -> ())
        in
        [ result ]
    | left :: right :: rest ->
        let #(left, right) =
          Parallel.fork_join2 parallel
            (fun _ -> capture_result f left)
            (fun _ -> capture_result f right)
        in
        left :: right :: result_outcomes_with_parallel parallel f rest

  let map_outcomes pool (f @ portable) inputs =
    ensure_running pool;
    Parallel_scheduler.parallel pool.scheduler ~f:(fun parallel ->
        map_outcomes_with_parallel parallel f inputs)

  let result_outcomes pool (f @ portable) inputs =
    ensure_running pool;
    Parallel_scheduler.parallel pool.scheduler ~f:(fun parallel ->
        result_outcomes_with_parallel parallel f inputs)

  let submit name pool (f @ portable) input =
    match map_outcomes pool f [ input ] with
    | [ Map_ok value ] -> value
    | [ Map_worker_died die ] -> raise_worker_die name die
    | _ -> assert false

  let submit_map name pool (f @ portable) inputs =
    map_outcomes pool f inputs
    |> List.map (function
         | Map_ok value -> value
         | Map_worker_died die -> raise_worker_die name die)

  let submit_map_result name pool (f @ portable) inputs =
    result_outcomes pool f inputs
    |> List.map (function
         | Result_ok value -> Stdlib.Ok value
         | Result_error error -> Stdlib.Error error
         | Result_worker_died die -> raise_worker_die name die)

  let submit_all_settled pool (f @ portable) inputs =
    result_outcomes pool f inputs
    |> List.map (function
         | Result_ok value -> Ok value
         | Result_error error -> Error error
         | Result_worker_died die -> Worker_died die)
end

module Blocking_runtime = struct
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

  type outcome =
    | Blocking_ok
    | Blocking_error of string
    | Blocking_cancelled
    | Blocking_rejected
    | Blocking_shutdown_rejected
    | Blocking_detached

  type event = {
    pool : string;
    name : string;
    queue_wait_ms : int;
    run_ms : int;
    outcome : outcome;
  }

  type kind = Systhread | Domain_isolated

  type t = {
    name : string;
    config : config;
    kind : kind;
    mutex : Eio.Mutex.t;
    condition : Eio.Condition.t;
    mutable active : int;
    mutable queued : int;
    mutable completed : int;
    mutable rejected : int;
    mutable cancelled_before_start : int;
    mutable detached : int;
    mutable shutdown : bool;
  }

  type packed_result = Packed_ok of Obj.t | Packed_error of exn * Printexc.raw_backtrace

  exception Pool_full of string
  exception Pool_shutting_down of string
  exception Blocking_worker_invariant_violation of string

  let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

  let default_config =
    {
      max_threads = 128;
      max_queued = 64;
      queue_policy = Wait;
      shutdown_policy = Drain;
    }

  let validate_config config =
    if config.max_threads <= 0 then
      invalid_arg "Effect.Blocking.Pool.create: max_threads must be > 0";
    if config.max_queued < 0 then
      invalid_arg "Effect.Blocking.Pool.create: max_queued must be >= 0"

  let create_with_kind kind ?(name = "blocking") config =
    validate_config config;
    {
      name;
      config;
      kind;
      mutex = Eio.Mutex.create ();
      condition = Eio.Condition.create ();
      active = 0;
      queued = 0;
      completed = 0;
      rejected = 0;
      cancelled_before_start = 0;
      detached = 0;
      shutdown = false;
    }

  module Worker_context = struct
    let mutex = Mutex.create ()
    let workers : (int, int) Hashtbl.t = Hashtbl.create 16

    let current_id () = Thread.id (Thread.self ())

    let enter () =
      let id = current_id () in
      Mutex.lock mutex;
      let count = Option.value (Hashtbl.find_opt workers id) ~default:0 in
      Hashtbl.replace workers id (count + 1);
      Mutex.unlock mutex;
      id

    let leave id =
      Mutex.lock mutex;
      let count = Option.value (Hashtbl.find_opt workers id) ~default:0 in
      if count <= 1 then Hashtbl.remove workers id
      else Hashtbl.replace workers id (count - 1);
      Mutex.unlock mutex

    let run f =
      let id = enter () in
      Fun.protect ~finally:(fun () -> leave id) f

    let active () =
      let id = current_id () in
      Mutex.lock mutex;
      let result = Hashtbl.mem workers id in
      Mutex.unlock mutex;
      result
  end

  let in_worker = Worker_context.active

  let check_not_worker operation =
    if in_worker () then
      raise
        (Blocking_worker_invariant_violation
           (operation
          ^ " must not be called from inside an Effect.Blocking worker callback"))

  let name t = t.name

  let stats t =
    Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
    {
      active = t.active;
      queued = t.queued;
      completed = t.completed;
      rejected = t.rejected;
      cancelled_before_start = t.cancelled_before_start;
      detached = t.detached;
    }

  let emit_event emit t name submitted_at started_at ended_at outcome =
    emit
      {
        pool = t.name;
        name;
        queue_wait_ms = max 0 (started_at - submitted_at);
        run_ms = max 0 (ended_at - started_at);
        outcome;
      }

  let raise_pool_full t name emit submitted_at =
    let ts = now_ms () in
    emit_event emit t name submitted_at ts ts Blocking_rejected;
    raise (Pool_full t.name)

  let raise_pool_shutting_down t name emit submitted_at =
    let ts = now_ms () in
    emit_event emit t name submitted_at ts ts Blocking_shutdown_rejected;
    raise (Pool_shutting_down t.name)

  let rec reserve_slot t name emit submitted_at =
    match
      Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
      if t.shutdown then `Shutdown
      else if t.active < t.config.max_threads then (
        t.active <- t.active + 1;
        `Started)
      else if t.queued < t.config.max_queued then (
        t.queued <- t.queued + 1;
        `Queued)
      else
        match t.config.queue_policy with
        | Reject ->
            t.rejected <- t.rejected + 1;
            `Reject
        | Wait -> `Wait_full
    with
    | `Started -> `Started
    | `Queued -> `Queued
    | `Shutdown -> raise_pool_shutting_down t name emit submitted_at
    | `Reject -> raise_pool_full t name emit submitted_at
    | `Wait_full ->
        Eio_unix.sleep 0.001;
        reserve_slot t name emit submitted_at

  let wait_queued_slot t name emit submitted_at =
    try
      let rec loop () =
        match
          Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
          if t.shutdown && t.config.shutdown_policy = Detach_started then (
            t.queued <- max 0 (t.queued - 1);
            Eio.Condition.broadcast t.condition;
            `Shutdown)
          else if t.active < t.config.max_threads then (
            t.queued <- max 0 (t.queued - 1);
            t.active <- t.active + 1;
            Eio.Condition.broadcast t.condition;
            `Started)
          else `Wait
        with
        | `Wait ->
            Eio_unix.sleep 0.001;
            loop ()
        | (`Started | `Shutdown) as state -> state
      in
      match loop () with
      | `Started -> ()
      | `Shutdown -> raise_pool_shutting_down t name emit submitted_at
    with (Eio.Cancel.Cancelled _ | Exit) ->
      let ts = now_ms () in
      Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
          t.queued <- max 0 (t.queued - 1);
          t.cancelled_before_start <- t.cancelled_before_start + 1;
          Eio.Condition.broadcast t.condition);
      emit_event emit t name submitted_at ts ts Blocking_cancelled;
      raise Exit

  let release_started t =
    Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
    t.active <- max 0 (t.active - 1);
    t.completed <- t.completed + 1;
    Eio.Condition.broadcast t.condition

  let mark_detached t count =
    if count > 0 then
      Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
      t.detached <- t.detached + count;
      Eio.Condition.broadcast t.condition

  let run_callback f =
    Worker_context.run @@ fun () ->
    try Packed_ok (Obj.repr (f ())) with exn ->
      Packed_error (exn, Printexc.get_raw_backtrace ())

  let run_systhread name f =
    Eio_unix.run_in_systhread ~label:name (fun () -> run_callback f)

  let run_domain f =
    let finished = Atomic.make false in
    let result = Atomic.make None in
    let domain =
      Domain.spawn (fun () ->
          let r = run_callback f in
          Atomic.set result (Some r);
          Atomic.set finished true)
    in
    while not (Atomic.get finished) do
      Eio_unix.sleep 0.001
    done;
    Domain.join domain;
    match Atomic.get result with Some r -> r | None -> assert false

  let run_worker t name f =
    match t.kind with
    | Systhread -> run_systhread name f
    | Domain_isolated -> run_domain f

  let finish_result t name emit submitted_at started_at outcome =
    let ended_at = now_ms () in
    release_started t;
    match outcome with
    | Packed_ok value ->
        emit_event emit t name submitted_at started_at ended_at Blocking_ok;
        Obj.obj value
    | Packed_error (exn, bt) ->
        emit_event emit t name submitted_at started_at ended_at
          (Blocking_error (Printexc.to_string exn));
        Printexc.raise_with_backtrace exn bt

  let submit ~sw ~emit t name f =
    check_not_worker "Effect.Blocking.submit";
    let submitted_at = now_ms () in
    (try
       match reserve_slot t name emit submitted_at with
       | `Started -> ()
       | `Queued -> wait_queued_slot t name emit submitted_at
     with Exit -> raise Exit);
    let started_at = now_ms () in
    match t.config.shutdown_policy with
    | Drain ->
        Eio.Cancel.protect @@ fun () ->
        let outcome = run_worker t name f in
        finish_result t name emit submitted_at started_at outcome
    | Detach_started ->
        let promise =
          Eio.Fiber.fork_promise ~sw (fun () ->
              let outcome = run_worker t name f in
              finish_result t name emit submitted_at started_at outcome)
        in
        (try Eio.Promise.await_exn promise with
        | Eio.Cancel.Cancelled _ as exn ->
            mark_detached t 1;
            let ts = now_ms () in
            emit_event emit t name submitted_at started_at ts Blocking_detached;
            raise exn)

  let shutdown ~emit t =
    let detached =
      Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
      t.shutdown <- true;
      let detached =
        match t.config.shutdown_policy with
        | Drain -> 0
        | Detach_started -> t.active
      in
      t.detached <- t.detached + detached;
      Eio.Condition.broadcast t.condition;
      detached
    in
    if detached > 0 then
      emit
        {
          pool = t.name;
          name = "blocking.shutdown";
          queue_wait_ms = 0;
          run_ms = 0;
          outcome = Blocking_detached;
        };
    match t.config.shutdown_policy with
    | Detach_started -> ()
    | Drain ->
        Eio.Mutex.use_rw ~protect:true t.mutex @@ fun () ->
        while t.active > 0 || t.queued > 0 do
          Eio.Condition.await t.condition t.mutex
        done

  module Pool = struct
    type nonrec t = t
    type nonrec queue_policy = queue_policy = Wait | Reject
    type nonrec shutdown_policy = shutdown_policy = Drain | Detach_started

    type nonrec config = config = {
      max_threads : int;
      max_queued : int;
      queue_policy : queue_policy;
      shutdown_policy : shutdown_policy;
    }

    type nonrec stats = stats = {
      active : int;
      queued : int;
      completed : int;
      rejected : int;
      cancelled_before_start : int;
      detached : int;
    }

    let create ?name config = create_with_kind Systhread ?name config
    let create_domain_isolated ?name config =
      create_with_kind Domain_isolated ?name config

    let stats = stats
  end
end

type ('a, 'err) t =
  | Pure : 'a -> ('a, _) t
  | Fail : 'err -> (_, 'err) t
  | Sync : string * (unit -> 'a) -> ('a, _) t
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
  | Blocking_shutdown : Blocking_runtime.t -> (unit, 'err) t
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
let sync name f = Sync (name, f)
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
let repeat sch e = Repeat (e, sch)

let acquire_release ~acquire ~release = Acquire_release (acquire, release)
let scoped e = Scoped e
let supervisor_scoped ?max_failures body =
  Supervisor_scoped (max_failures, body)

let with_error_renderer render e = Render_error (render, e)

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
  | Named (_, n, _) -> Some n
  | Annotate (_, _, e) -> name e
  | _ -> None

let collect_names e =
  let rec walk : type a err. string list -> (a, err) t -> string list =
   fun acc -> function
    | Pure _ -> acc
    | Fail _ -> acc
    | Sync (n, _) -> n :: acc
    | Island { name; _ }
    | Island_map { name; _ }
    | Island_map_result { name; _ }
    | Island_all_settled { name; _ } ->
        name :: acc
    | Blocking { name; _ } -> name :: acc
    | Blocking_shutdown _ -> acc
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
    | Sync : string * (unit -> 'a) -> ('a, _) view
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
