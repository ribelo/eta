module E = Effect
module EP = Effect.Private
module EV = Effect_view
module P_atomic = Portable.Atomic
module RObs = Runtime_observability
module Sch = Schedule

(* Typed failures cross Eio fibers through OCaml exceptions. The [Obj.t] payload
   is private to this module and is unpacked only after the fresh [Typed_fail]
   key matches the interpreter frame that packed it. *)
exception Raised_cause of int * Obj.t
exception Timeout_as_fired of int

module Typed_fail : sig
  type key

  val fresh : unit -> key
  val int : key -> int
end = struct
  type key = int
  let counter = Atomic.make 0
  let fresh () = Atomic.fetch_and_add counter 1 + 1
  let int key = key
end

let raise_cause key cause =
  raise (Raised_cause (Typed_fail.int key, Obj.repr cause))

let raise_fail key err = raise_cause key (Cause.Fail err)

let rec cause_of_exn ?backtrace ~capture_backtrace key exn =
  match exn with
  | Raised_cause (k, cause) when k = Typed_fail.int key -> Obj.obj cause
  | Eio.Cancel.Cancelled _ -> Cause.interrupt
  | Exit -> Cause.interrupt
  | Fun.Finally_raised exn -> cause_of_exn ~capture_backtrace key exn
  | Eio.Exn.Multiple causes ->
      let causes =
        List.map
          (fun (exn, bt) ->
            cause_of_exn ~backtrace:bt ~capture_backtrace key exn)
          causes
      in
      if List.for_all Cause.is_interrupt_only causes then Cause.interrupt
      else Cause.concurrent causes
  | exn -> RObs.die_of_exn ?backtrace ~capture_backtrace exn

type 'err t = {
  sleep : Duration.t -> unit;
  now_ms : unit -> int;
  tracer : Capabilities.tracer;
  tracing_enabled : bool;
  sampler : Sampler.t;
  auto_instrument : bool;
  logger : Capabilities.logger;
  logging_enabled : bool;
  meter : Capabilities.meter;
  metrics_enabled : bool;
  random : Capabilities.random;
  island_pool : E.Island.pool option;
  blocking_pool : E.Blocking.Pool.t option;
  default_blocking_pool : E.Blocking.Pool.t Lazy.t;
  capture_backtrace : bool;
  outer_sw : Eio.Switch.t;
  active : int P_atomic.t;
  default_fail_key : Typed_fail.key;
}

let create ~sw ~clock ?sleep ?tracer ?(sampler = Sampler.always_on)
    ?(auto_instrument = false) ?logger ?meter ?random ?island_pool
    ?blocking_pool ?(capture_backtrace = true) () =
  let clock = (clock :> float Eio.Time.clock_ty Eio.Std.r) in
  let tracer = Option.value tracer ~default:Tracer.noop in
  let logger = Option.value logger ~default:Logger.noop in
  let meter = Option.value meter ~default:Meter.noop in
  let sleep =
    match sleep with
    | Some sleep -> sleep
    | None ->
        fun d ->
          let secs = Duration.to_seconds_float d in
          if secs > 0.0 then Eio.Time.sleep clock secs
  in
  let now_ms () =
    let secs = Eio.Time.now clock in
    int_of_float (secs *. 1000.0)
  in
  let random =
    match random with
    | Some random -> random
    | None ->
        let seed =
          int_of_float (Eio.Time.now clock *. 1_000_000.0) land 0x3fffffff
        in
        Capabilities.random_of_seed seed
  in
  {
    sleep;
    now_ms;
    tracer;
    tracing_enabled = tracer != Tracer.noop;
    sampler;
    auto_instrument;
    logger;
    logging_enabled = logger != Logger.noop;
    meter;
    metrics_enabled = meter != Meter.noop;
    random;
    island_pool;
    blocking_pool;
    default_blocking_pool =
      lazy
        (E.Blocking.Pool.create ~name:"runtime.default"
           E.Private.blocking_default_config);
    capture_backtrace;
    outer_sw = sw;
    active = P_atomic.make 0;
    default_fail_key = Typed_fail.fresh ();
  }

let emit_daemon_failure runtime cause =
  RObs.emit_daemon_failure ~now_ms:runtime.now_ms
    ~logging_enabled:runtime.logging_enabled ~logger:runtime.logger
    ~tracing_enabled:runtime.tracing_enabled ~tracer:runtime.tracer cause

let cause_of_exn_runtime runtime key exn =
  cause_of_exn ~capture_backtrace:runtime.capture_backtrace key exn

let die_of_exn_runtime runtime exn =
  RObs.die_of_exn ~capture_backtrace:runtime.capture_backtrace exn

let rec has_timeout_as token = function
  | Timeout_as_fired observed -> observed = token
  | Fun.Finally_raised exn -> has_timeout_as token exn
  | Eio.Exn.Multiple causes ->
      List.exists (fun (exn, _) -> has_timeout_as token exn) causes
  | _ -> false

let rec only_timeout_as_or_interrupt token = function
  | Timeout_as_fired observed -> observed = token
  | Eio.Cancel.Cancelled _ | Exit -> true
  | Raised_cause (_, cause) -> (
      let rec only_fail_or_interrupt : _ Cause.t -> bool = function
        | Cause.Fail _ | Cause.Interrupt _ -> true
        | Cause.Sequential causes | Cause.Concurrent causes ->
            List.for_all only_fail_or_interrupt causes
        | Cause.Suppressed _ | Cause.Die _ -> false
      in
      match Obj.obj cause with
      | cause when only_fail_or_interrupt cause -> true
      | cause -> Cause.is_interrupt_only cause)
  | Fun.Finally_raised exn -> only_timeout_as_or_interrupt token exn
  | Eio.Exn.Multiple causes ->
      List.for_all
        (fun (exn, _) -> only_timeout_as_or_interrupt token exn)
        causes
  | _ -> false

let cause_of_timeout_as_exn runtime fail_key token on_timeout exn =
  let rec convert ?backtrace = function
    | Timeout_as_fired observed when observed = token -> Cause.Fail on_timeout
    | Fun.Finally_raised exn -> convert ?backtrace exn
    | Eio.Exn.Multiple causes ->
        causes
        |> List.map (fun (exn, bt) -> convert ~backtrace:bt exn)
        |> Cause.concurrent
    | exn ->
        cause_of_exn ?backtrace ~capture_backtrace:runtime.capture_backtrace
          fail_key exn
  in
  convert exn

let island_pool runtime override =
  match override with
  | Some pool -> pool
  | None -> (
      match runtime.island_pool with
      | Some pool -> pool
      | None -> failwith "Effect.island: island executor not configured")

let blocking_pool runtime override =
  match override with
  | Some pool -> pool
  | None -> (
      match runtime.blocking_pool with
      | Some pool -> pool
      | None -> Lazy.force runtime.default_blocking_pool)

let emit_blocking_event runtime event =
  RObs.emit_blocking_event ~now_ms:runtime.now_ms
    ~tracing_enabled:runtime.tracing_enabled ~tracer:runtime.tracer
    ~metrics_enabled:runtime.metrics_enabled ~meter:runtime.meter event

let run_finalizers ~runtime ~fail_key finalizers =
  Eio.Cancel.protect @@ fun () ->
  match !finalizers with
  | [] -> None
  | fs ->
      finalizers := [];
      let failures = Array.make (List.length fs) None in
      Eio.Fiber.all
        (List.mapi
           (fun i f () ->
             try f () with exn ->
               failures.(i) <- Some (cause_of_exn_runtime runtime fail_key exn))
          fs);
      failures
      |> Array.to_list
      |> List.filter_map Fun.id
      |> (function [] -> None | causes -> Some (Cause.concurrent causes))

let with_finalizers ~runtime ~fail_key finalizers body =
  match body () with
  | value -> (
      match run_finalizers ~runtime ~fail_key finalizers with
      | None -> value
      | Some finalizer -> raise_cause fail_key finalizer)
  | exception exn ->
      let primary = cause_of_exn_runtime runtime fail_key exn in
      let cause =
        match run_finalizers ~runtime ~fail_key finalizers with
        | None -> primary
        | Some finalizer -> Cause.suppressed ~primary ~finalizer
      in
      raise_cause fail_key cause

let rec interpret :
    type err a.
    runtime:_ t ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (a, err) E.t ->
    a =
 fun ~runtime ~error_renderer ~fail_key ~sw ~finalizers eff ->
  match EV.view eff with
  | EV.Pure v -> v
  | EV.Fail e -> raise_fail fail_key e
  | EV.Sync f -> f ()
  | EV.Island { name; f; input } ->
      let run () = EP.island_submit name (island_pool runtime None) f input in
      if runtime.auto_instrument then
        instrument_leaf ~runtime ~error_renderer ~fail_key ~name run
      else run ()
  | EV.Island_map { name; pool; f; inputs } ->
      let run () =
        EP.island_submit_map name (island_pool runtime pool) f inputs
      in
      if runtime.auto_instrument then
        instrument_leaf ~runtime ~error_renderer ~fail_key ~name run
      else run ()
  | EV.Island_map_result { name; pool; f; inputs } ->
      let run () =
        EP.island_submit_map_result name (island_pool runtime pool) f inputs
      in
      if runtime.auto_instrument then
        instrument_leaf ~runtime ~error_renderer ~fail_key ~name run
      else run ()
  | EV.Island_all_settled { name; pool; f; inputs } ->
      let run () =
        EP.island_submit_all_settled (island_pool runtime pool) f inputs
      in
      if runtime.auto_instrument then
        instrument_leaf ~runtime ~error_renderer ~fail_key ~name run
      else run ()
  | EV.Blocking { name; pool; f } ->
      let run () =
        EP.blocking_submit ~sw:runtime.outer_sw
          ~emit:(emit_blocking_event runtime) (blocking_pool runtime pool) name f
      in
      if runtime.auto_instrument then
        instrument_leaf ~runtime ~error_renderer ~fail_key ~name run
      else run ()
  | EV.Blocking_shutdown pool ->
      EP.blocking_shutdown ~emit:(emit_blocking_event runtime) pool
  | EV.Bind (e, k) ->
      let v = interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e in
      interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers (k v)
  | EV.Map (e, f) ->
      f (interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e)
  | EV.Catch (e, handler) ->
      let inner_key = Typed_fail.fresh () in
      (try
         interpret ~runtime ~error_renderer:RObs.default_error_renderer
           ~fail_key:inner_key ~sw ~finalizers e
       with
      | Raised_cause (k, cause) when k = Typed_fail.int inner_key -> (
          match Obj.obj cause with
          | Cause.Fail err ->
              interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers
                (handler err)
          | cause -> raise_cause fail_key cause)
      | Eio.Cancel.Cancelled _ -> raise_cause fail_key Cause.interrupt
      | exn -> raise_cause fail_key (cause_of_exn_runtime runtime inner_key exn))
  | EV.Tap_error (e, observe) ->
      let inner_key = Typed_fail.fresh () in
      (try
         interpret ~runtime ~error_renderer ~fail_key:inner_key ~sw ~finalizers e
       with
      | Raised_cause (k, cause) when k = Typed_fail.int inner_key -> (
          match Obj.obj cause with
          | Cause.Fail err ->
              let primary = Cause.Fail err in
              (try observe err with exn ->
                 let finalizer = cause_of_exn_runtime runtime fail_key exn in
                 raise_cause fail_key (Cause.suppressed ~primary ~finalizer));
              raise_fail fail_key err
          | cause -> raise_cause fail_key cause)
      | Eio.Cancel.Cancelled _ -> raise_cause fail_key Cause.interrupt
      | exn -> raise_cause fail_key (cause_of_exn_runtime runtime inner_key exn))
  | EV.Delay (d, e) ->
      runtime.sleep d;
      interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
  | EV.Timeout (d, e) ->
      let rec has_timeout : _ Cause.t -> bool = function
        | Cause.Fail `Timeout -> true
        | Cause.Sequential causes | Cause.Concurrent causes ->
            List.exists has_timeout causes
        | Cause.Suppressed { primary; finalizer } ->
            has_timeout primary || has_timeout finalizer
        | Cause.Fail _ | Cause.Die _ | Cause.Interrupt _ -> false
      in
      let rec only_timeout_or_interrupt : _ Cause.t -> bool = function
        | Cause.Fail `Timeout | Cause.Interrupt _ -> true
        | Cause.Sequential causes | Cause.Concurrent causes ->
            List.for_all only_timeout_or_interrupt causes
        | Cause.Suppressed { primary; finalizer } ->
            only_timeout_or_interrupt primary
            && only_timeout_or_interrupt finalizer
        | Cause.Fail _ | Cause.Die _ -> false
      in
      (try
         Eio.Fiber.first
           (fun () ->
             runtime.sleep d;
             raise_fail fail_key `Timeout)
           (fun () ->
             interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e)
       with exn ->
         let cause = cause_of_exn_runtime runtime fail_key exn in
         if has_timeout cause && only_timeout_or_interrupt cause then
           raise_fail fail_key `Timeout
         else raise_cause fail_key cause)
  | EV.Timeout_as (d, on_timeout, e) ->
      let token = Typed_fail.int (Typed_fail.fresh ()) in
      (try
         Eio.Fiber.first
           (fun () ->
             runtime.sleep d;
             raise (Timeout_as_fired token))
           (fun () ->
             interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e)
       with exn ->
         if
           has_timeout_as token exn
           && only_timeout_as_or_interrupt token exn
         then raise_fail fail_key on_timeout
         else
           raise_cause fail_key
             (cause_of_timeout_as_exn runtime fail_key token on_timeout exn))
  | EV.Concat children ->
      List.iter
        (fun child ->
          let () =
            interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers child
          in
          ())
        children
  | EV.Race children ->
      race_first ~runtime ~error_renderer ~fail_key ~finalizers children
  | EV.Par (a, b) ->
      (* [par_collect] needs a homogeneous task list, while [Effect.par] returns
         a heterogeneous pair. These casts are slot-local: each packed result is
         unpacked exactly at the slot whose task produced it. *)
      let tasks : (unit -> Obj.t) list =
        [
          (fun () ->
            Obj.repr
              (interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers a));
          (fun () ->
            Obj.repr
              (interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers b));
        ]
      in
      (match par_collect ~runtime ~fail_key ~finalizers tasks with
       | [ va; vb ] -> (Obj.obj va, Obj.obj vb)
       | _ -> assert false)
  | EV.All children ->
      par_collect ~runtime ~fail_key ~finalizers
        (List.map
           (fun child () ->
             interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers child)
           children)
  | EV.All_settled children ->
      par_collect_settled ~runtime ~error_renderer:RObs.default_error_renderer
        ~fail_key ~finalizers children
  | EV.For_each_par (xs, f) ->
      par_collect ~runtime ~fail_key ~finalizers
        (List.map
           (fun x () ->
             interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers (f x))
           xs)
  | EV.For_each_par_bounded (max, xs, f) ->
      let semaphore = Eio.Semaphore.make max in
      par_collect ~runtime ~fail_key ~finalizers
        (List.map
           (fun x () ->
             Eio.Semaphore.acquire semaphore;
             Fun.protect
               ~finally:(fun () -> Eio.Semaphore.release semaphore)
               (fun () ->
                 interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers (f x)))
           xs)
  | EV.Daemon e -> daemon_effect ~runtime e
  | EV.Uninterruptible e ->
      Eio.Cancel.protect (fun () ->
          interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e)
  | EV.Repeat (e, schedule) ->
      repeat_eff ~runtime ~error_renderer ~fail_key ~sw ~finalizers e schedule
  | EV.Retry (e, schedule, predicate) ->
      retry_eff ~runtime ~error_renderer ~fail_key ~sw ~finalizers e schedule
        predicate
  | EV.Acquire_release (acquire, release) ->
      let v =
        interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers acquire
      in
      finalizers :=
        (fun () ->
          let release_finalizers = ref [] in
          with_finalizers ~runtime ~fail_key release_finalizers (fun () ->
              interpret ~runtime ~error_renderer ~fail_key ~sw
                ~finalizers:release_finalizers (release v)))
        :: !finalizers;
      v
  | EV.Scoped e ->
      Eio.Switch.run @@ fun sw' ->
      let child_finalizers = ref [] in
      with_finalizers ~runtime ~fail_key child_finalizers (fun () ->
          interpret ~runtime ~error_renderer ~fail_key ~sw:sw'
            ~finalizers:child_finalizers e)
  | EV.Supervisor_scoped (max_failures, body) ->
      Eio.Switch.run @@ fun supervisor_sw ->
      let supervisor =
        EP.make_supervisor ~sw:supervisor_sw ~max_failures
      in
      let supervisor_finalizers = ref [] in
      with_finalizers ~runtime ~fail_key supervisor_finalizers (fun () ->
          Fun.protect
            ~finally:(fun () -> EP.supervisor_cancel_children supervisor)
            (fun () ->
              interpret_supervisor_scope ~runtime ~error_renderer ~fail_key
                ~sw:supervisor_sw
                ~finalizers:supervisor_finalizers (body.run supervisor)))
  | EV.Render_error (render, e) ->
      interpret ~runtime ~error_renderer:render ~fail_key ~sw ~finalizers e
  | EV.Suppress_observability e ->
      let runtime =
        {
          runtime with
          tracing_enabled = false;
          auto_instrument = false;
          logging_enabled = false;
          metrics_enabled = false;
        }
      in
      interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
  | EV.Named (kind, name, e) ->
      interpret_named ~runtime ~error_renderer ~fail_key ~sw ~finalizers ~kind
        ~name ~attrs:[] e
  | EV.Named_attrs (kind, name, attrs, e) ->
      interpret_named ~runtime ~error_renderer ~fail_key ~sw ~finalizers ~kind
        ~name ~attrs e
  | EV.Annotate (key, value, e) ->
      (if runtime.tracing_enabled then
         match Eio.Fiber.get RObs.active_span_key with
         | Some span_id -> runtime.tracer#add_attr_to ~span_id ~key ~value
         | None -> runtime.tracer#add_attr ~key ~value);
      RObs.with_die_annotation key value @@ fun () ->
      (try
         interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
       with exn ->
         raise_cause fail_key (cause_of_exn_runtime runtime fail_key exn))
  | EV.Link_span (link, e) ->
      (if runtime.tracing_enabled then
         match Eio.Fiber.get RObs.active_span_key with
         | Some span_id -> runtime.tracer#add_link_to ~span_id link
         | None -> runtime.tracer#add_link link);
      interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
  | EV.With_external_parent (ctx, e) | EV.With_context (ctx, e) ->
      if runtime.tracing_enabled then
        Eio.Fiber.with_binding RObs.trace_context_key ctx @@ fun () ->
        Eio.Fiber.with_binding RObs.sampled_key (Trace_context.sampled ctx) @@ fun () ->
        interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
      else
        Eio.Fiber.with_binding RObs.trace_context_key ctx @@ fun () ->
        interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
  | EV.Current_span -> (
      if not runtime.tracing_enabled then None
      else
        match Eio.Fiber.get RObs.active_span_key with
        | None -> None
        | Some span_id -> runtime.tracer#inspect ~span_id)
  | EV.Current_context -> (
      if not runtime.tracing_enabled then Eio.Fiber.get RObs.trace_context_key
      else
        match Eio.Fiber.get RObs.active_span_key with
        | Some span_id -> (
            match runtime.tracer#inspect ~span_id with
            | Some info ->
                Some
                  {
                    Capabilities.trace_id = info.trace_id;
                    span_id = info.span_id;
                    trace_flags = info.trace_flags;
                    trace_state = info.trace_state;
                    baggage = info.baggage;
                  }
            | None -> Eio.Fiber.get RObs.trace_context_key)
        | None -> Eio.Fiber.get RObs.trace_context_key)
  | EV.Log (level, body, attrs) ->
      if runtime.logging_enabled then (
        let trace_id, span_id =
          if not runtime.tracing_enabled then ("", "")
          else
            match Eio.Fiber.get RObs.active_span_key with
            | None -> ("", "")
            | Some span_id -> (
                match runtime.tracer#inspect ~span_id with
                | None -> ("", "")
                | Some info -> (info.trace_id, info.span_id))
        in
        runtime.logger#log
          {
            Capabilities.level;
            body;
            ts_ms = runtime.now_ms ();
            attrs;
            trace_id;
            span_id;
          })
  | EV.Metric_update { name; description; unit_; kind; attrs; value } ->
      if runtime.metrics_enabled then
        runtime.meter#record ~name ~description ~unit_ ~kind ~attrs ~value
          ~ts_ms:(runtime.now_ms ())
  | EV.Metric_updates updates ->
      if runtime.metrics_enabled then
        let ts_ms = runtime.now_ms () in
        List.iter
          (fun (name, description, unit_, kind, attrs, value) ->
            runtime.meter#record ~name ~description ~unit_ ~kind ~attrs ~value
              ~ts_ms)
          updates
  | EV.Metric_updates_lazy make_updates ->
      if runtime.metrics_enabled then
        let ts_ms = runtime.now_ms () in
        List.iter
          (fun (name, description, unit_, kind, attrs, value) ->
            runtime.meter#record ~name ~description ~unit_ ~kind ~attrs ~value
              ~ts_ms)
          (make_updates ())

and interpret_named :
    type err a.
    runtime:_ t ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    kind:Capabilities.span_kind ->
    name:string ->
    attrs:(string * string) list ->
    (a, err) E.t ->
    a =
 fun ~runtime ~error_renderer ~fail_key ~sw ~finalizers ~kind ~name ~attrs e ->
  let run_body () =
    try interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
    with exn ->
      raise_cause fail_key (cause_of_exn_runtime runtime fail_key exn)
  in
  let with_die_context f =
    RObs.with_die_span_name name @@ fun () -> RObs.with_die_annotations attrs f
  in
  if not runtime.tracing_enabled then with_die_context run_body
  else
    let parent_id = Eio.Fiber.get RObs.active_span_key in
    let ambient_context = Eio.Fiber.get RObs.trace_context_key in
    let parent_sampled =
      Option.value (Eio.Fiber.get RObs.sampled_key)
        ~default:
          (match ambient_context with
          | None -> true
          | Some ctx -> Trace_context.sampled ctx)
    in
    let external_parent =
      match parent_id with
      | Some _ -> None
      | None -> ambient_context
    in
    let sampled =
      parent_sampled
      && Sampler.sample runtime.sampler ~trace_id:"" ~name ~attrs:[]
           ~parent:(Option.is_some parent_id || Option.is_some ambient_context)
    in
    if not sampled then
      with_die_context @@ fun () ->
      Eio.Fiber.with_binding RObs.sampled_key false run_body
    else
      let started_ms = runtime.now_ms () in
      let span_id =
        runtime.tracer#begin_span ?parent_id ?external_parent ~name ~kind
          ~started_ms ()
      in
      let finish status =
        let ended_ms = runtime.now_ms () in
        runtime.tracer#end_span ~span_id ~status ~ended_ms
      in
      let emit_exception_event cause =
        let events = RObs.exception_event_attrs_tree ~error_renderer cause in
        List.iter
          (fun attrs ->
            runtime.tracer#add_event ~span_id ~name:"exception"
              ~ts_ms:(runtime.now_ms ()) ~attrs)
          events
      in
      with_die_context @@ fun () ->
      Eio.Fiber.with_binding RObs.active_span_key span_id @@ fun () ->
      Eio.Fiber.with_binding RObs.sampled_key true @@ fun () ->
      try
        List.iter
          (fun (key, value) -> runtime.tracer#add_attr_to ~span_id ~key ~value)
          attrs;
        let value =
          interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
        in
        finish Ok;
        value
      with exn ->
        let cause = cause_of_exn_runtime runtime fail_key exn in
        emit_exception_event cause;
        finish (RObs.status_of_cause ~error_renderer cause);
        raise_cause fail_key cause

and instrument_leaf :
    type err a.
    runtime:_ t ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    name:string ->
    (unit -> a) ->
    a =
 fun ~runtime ~error_renderer ~fail_key ~name f ->
  if not runtime.tracing_enabled then
    RObs.with_die_span_name name @@ fun () ->
    try f () with exn ->
      raise_cause fail_key (cause_of_exn_runtime runtime fail_key exn)
  else
    let parent_id = Eio.Fiber.get RObs.active_span_key in
    let ambient_context = Eio.Fiber.get RObs.trace_context_key in
    let parent_sampled =
      Option.value (Eio.Fiber.get RObs.sampled_key)
        ~default:
          (match ambient_context with
          | None -> true
          | Some ctx -> Trace_context.sampled ctx)
    in
    let external_parent =
      match parent_id with
      | Some _ -> None
      | None -> ambient_context
    in
    let sampled =
      parent_sampled
      && Sampler.sample runtime.sampler ~trace_id:"" ~name ~attrs:[]
           ~parent:(Option.is_some parent_id || Option.is_some ambient_context)
    in
    if not sampled then
      RObs.with_die_span_name name @@ fun () ->
      try f () with exn ->
        raise_cause fail_key (cause_of_exn_runtime runtime fail_key exn)
    else
      let started_ms = runtime.now_ms () in
      let span_id =
        runtime.tracer#begin_span ?parent_id ?external_parent ~name ~started_ms
          ~kind:Capabilities.Internal ()
      in
      let finish status =
        runtime.tracer#end_span ~span_id ~status ~ended_ms:(runtime.now_ms ())
      in
      RObs.with_die_span_name name @@ fun () ->
      Eio.Fiber.with_binding RObs.active_span_key span_id @@ fun () ->
      Eio.Fiber.with_binding RObs.sampled_key true @@ fun () ->
      try
        let value = f () in
        finish Ok;
        value
      with exn ->
        let cause = cause_of_exn_runtime runtime fail_key exn in
        RObs.exception_event_attrs_tree ~error_renderer cause
        |> List.iter (fun attrs ->
               runtime.tracer#add_event ~span_id ~name:"exception"
                 ~ts_ms:(runtime.now_ms ()) ~attrs);
        finish (RObs.status_of_cause ~error_renderer cause);
        raise_cause fail_key cause

and interpret_supervisor_scope :
    type s err a.
    runtime:_ t ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (s, a, err) E.supervisor_scope ->
    a =
 fun ~runtime ~error_renderer ~fail_key ~sw ~finalizers eff ->
  match eff with
  | E.Supervisor_pure value -> value
  | E.Supervisor_lift child_effect ->
      interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers child_effect
  | E.Supervisor_fail err -> raise_fail fail_key err
  | E.Supervisor_bind (scope_effect, k) ->
      let value =
        interpret_supervisor_scope ~runtime ~error_renderer ~fail_key ~sw
          ~finalizers scope_effect
      in
      interpret_supervisor_scope ~runtime ~error_renderer ~fail_key ~sw
        ~finalizers (k value)
  | E.Supervisor_start (supervisor, child_effect) ->
      let promise, resolver = Eio.Promise.create () in
      let resolved = Atomic.make false in
      let cancel_requested = Atomic.make false in
      let resolve value =
        if Atomic.compare_and_set resolved false true then
          Eio.Promise.resolve resolver value
      in
      let child_sw = ref None in
      let child_cancel = ref None in
      E.Private.supervisor_fork supervisor (fun () ->
          Tracer.with_fiber_context @@ fun () ->
          let result =
            try
              Eio.Cancel.sub @@ fun cancel_context ->
              child_cancel := Some cancel_context;
              if Atomic.get cancel_requested then
                Eio.Cancel.cancel cancel_context Exit;
              Eio.Switch.run @@ fun child_switch ->
              child_sw := Some child_switch;
              let child_finalizers = ref [] in
              Ok
                (with_finalizers ~runtime ~fail_key child_finalizers (fun () ->
                     interpret_supervisor_scope ~runtime
                       ~error_renderer:RObs.default_error_renderer ~fail_key
                       ~sw:child_switch ~finalizers:child_finalizers child_effect))
            with exn -> Error (cause_of_exn_runtime runtime fail_key exn)
          in
          (match result with
          | Ok _ -> ()
          | Error cause ->
              E.Private.supervisor_record_failure supervisor cause);
          resolve result);
      let cancel () =
        if not (Atomic.get resolved) then (
          Atomic.set cancel_requested true;
          match !child_cancel with
          | None -> resolve (Error Cause.interrupt)
          | Some cancel_context ->
              Eio.Cancel.cancel cancel_context Exit;
              (match !child_sw with
              | None -> ()
              | Some child_switch ->
                  (try Eio.Switch.fail child_switch Exit with _ -> ())))
      in
      E.Private.supervisor_register_child supervisor cancel;
      E.Private.make_supervisor_child ~promise ~cancel
  | E.Supervisor_await child -> (
      match Eio.Promise.await (E.Private.supervisor_child_promise child) with
      | Ok value -> value
      | Error cause -> raise_cause fail_key cause)
  | E.Supervisor_cancel child ->
      E.Private.supervisor_child_cancel child ()
  | E.Supervisor_failures supervisor ->
      List.rev (E.Private.supervisor_failures supervisor)
  | E.Supervisor_check supervisor -> (
      match E.Private.supervisor_max_failures supervisor with
      | None -> ()
      | Some max ->
          let count = E.Private.supervisor_failure_count supervisor in
          if count >= max then raise_fail fail_key (`Supervisor_failed count))
  | E.Supervisor_yield -> Eio.Fiber.yield ()

and par_collect :
    type err a.
    runtime:_ t ->
    fail_key:Typed_fail.key ->
    finalizers:(unit -> unit) list ref ->
    (unit -> a) list ->
    a list =
 fun ~runtime ~fail_key ~finalizers:_ tasks ->
  let n = List.length tasks in
  let results : a option array = Array.make n None in
  let causes : err Cause.t list ref = ref [] in
  let exception Stop in
  (try
     Eio.Switch.run @@ fun par_sw ->
     List.iteri
       (fun i task ->
         Eio.Fiber.fork ~sw:par_sw (fun () ->
           Tracer.with_fiber_context @@ fun () ->
             try results.(i) <- Some (task ())
             with exn ->
               let cause = cause_of_exn_runtime runtime fail_key exn in
               causes := cause :: !causes;
               (try Eio.Switch.fail par_sw Stop with _ -> ())))
       tasks
   with Stop -> ());
  match List.rev !causes with
  | [] -> Array.to_list results |> List.map Option.get
  | causes -> raise_cause fail_key (Cause.concurrent causes)

and race_first :
    type err a.
    runtime:_ t ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    finalizers:(unit -> unit) list ref ->
    (a, err) E.t list ->
    a =
 fun ~runtime ~error_renderer ~fail_key ~finalizers children ->
  match children with
  | [] -> failwith "Effect.race: empty list"
  | _ ->
      (* The local [Race_won] exception cannot carry the existential success
         type [a]. [winner] never leaves this frame and is unpacked only after
         the winning child stores a value of that same [a]. *)
      let winner = ref None in
      let n = List.length children in
      let exception Race_won in
      (try
         Eio.Switch.run @@ fun race_sw ->
         let results = Eio.Stream.create n in
         List.iter
           (fun child ->
             Eio.Fiber.fork ~sw:race_sw (fun () ->
                Tracer.with_fiber_context @@ fun () ->
                try
                  let value =
                    interpret ~runtime ~error_renderer ~fail_key ~sw:race_sw
                      ~finalizers child
                  in
                  Eio.Stream.add results (`Ok value)
                with exn ->
                  Eio.Stream.add results
                    (`Error (cause_of_exn_runtime runtime fail_key exn))))
           children;
         let rec await_success causes remaining =
           if remaining = 0 then
             match List.rev causes with
             | [] -> failwith "Effect.race: no children"
             | causes -> raise_cause fail_key (Cause.concurrent causes)
           else
             match Eio.Stream.take results with
             | `Ok value ->
                 winner := Some (Obj.repr value);
                 Eio.Switch.fail race_sw Race_won;
                 Eio.Fiber.await_cancel ()
             | `Error child_cause ->
                 await_success (child_cause :: causes) (remaining - 1)
         in
         await_success [] n
       with Race_won -> Obj.obj (Option.get !winner))

and par_collect_settled :
    type err a.
    runtime:_ t ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    finalizers:(unit -> unit) list ref ->
    (a, err) E.t list ->
    (a, err Cause.t) result list =
 fun ~runtime ~error_renderer ~fail_key ~finalizers children ->
  let n = List.length children in
  let results : (a, err Cause.t) result option array = Array.make n None in
  (Eio.Switch.run @@ fun par_sw ->
   List.iteri
     (fun i child ->
       Eio.Fiber.fork ~sw:par_sw (fun () ->
           Tracer.with_fiber_context @@ fun () ->
           results.(i) <-
             Some
               (try
                  Ok
                    (interpret ~runtime ~error_renderer ~fail_key ~sw:par_sw
                       ~finalizers child)
                with exn ->
                  Error (cause_of_exn_runtime runtime fail_key exn))))
     children);
  Array.to_list results |> List.map Option.get

and daemon_effect :
    type err.
    runtime:_ t -> (unit, err) E.t -> unit =
 fun ~runtime eff -> fork_internal ~runtime eff

and fork_internal :
    type err.
    runtime:_ t -> (unit, err) E.t -> unit =
 fun ~runtime eff ->
  P_atomic.incr runtime.active;
  Eio.Fiber.fork_daemon ~sw:runtime.outer_sw (fun () ->
      Tracer.with_fiber_context @@ fun () ->
      Fun.protect
        ~finally:(fun () -> P_atomic.decr runtime.active)
        (fun () ->
          (try
             Eio.Switch.run @@ fun sw' ->
             let finalizers = ref [] in
             with_finalizers ~runtime ~fail_key:runtime.default_fail_key
               finalizers (fun () ->
                 interpret ~runtime ~error_renderer:RObs.default_error_renderer
                   ~fail_key:runtime.default_fail_key ~sw:sw' ~finalizers eff)
           with exn ->
             cause_of_exn_runtime runtime runtime.default_fail_key exn
             |> emit_daemon_failure runtime);
          `Stop_daemon))

and repeat_eff :
    type err.
    runtime:_ t ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (unit, err) E.t ->
    Sch.t ->
    unit =
 fun ~runtime ~error_renderer ~fail_key ~sw ~finalizers e schedule ->
  interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e;
  let driver = ref (Sch.start ~random:runtime.random schedule) in
  let continue = ref true in
  while !continue do
    match Sch.next !driver with
    | None -> continue := false
    | Some (d, next_driver) ->
        driver := next_driver;
        runtime.sleep d;
        interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
  done

and retry_eff :
    type err a.
    runtime:_ t ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (a, err) E.t ->
    Sch.t ->
    (err -> bool) ->
    a =
 fun ~runtime ~error_renderer ~fail_key ~sw ~finalizers e schedule predicate ->
  let attempt_key = Typed_fail.fresh () in
  let driver = ref (Sch.start ~random:runtime.random schedule) in
  let result : a option ref = ref None in
  while Option.is_none !result do
    (try
       let v =
         interpret ~runtime ~error_renderer ~fail_key:attempt_key ~sw ~finalizers e
       in
       result := Some v
     with
     | Raised_cause (k, cause) when k = Typed_fail.int attempt_key -> (
         match Obj.obj cause with
         | Cause.Fail err ->
             if predicate err then
               match Sch.next !driver with
               | Some (d, next_driver) ->
                   driver := next_driver;
                   runtime.sleep d;
               | None -> raise_fail fail_key err
             else raise_fail fail_key err
         | cause -> raise_cause fail_key cause)
     | Eio.Cancel.Cancelled _ -> raise_cause fail_key Cause.interrupt
     | exn ->
         raise_cause fail_key (cause_of_exn_runtime runtime attempt_key exn))
  done;
  Option.get !result

let run ?island_pool ?blocking_pool t eff =
  if EP.in_blocking_worker () then
    invalid_arg
      "Eta.Runtime.run must not be called from inside an Effect.Blocking worker callback";
  let t =
    match (island_pool, blocking_pool) with
    | None, None -> t
    | _ ->
        {
          t with
          island_pool =
            (match island_pool with Some _ as pool -> pool | None -> t.island_pool);
          blocking_pool =
            (match blocking_pool with
            | Some _ as pool -> pool
            | None -> t.blocking_pool);
        }
  in
  (* Fast path for terminal nodes: returning a pure value or a typed
     failure does not need a fresh switch, a tracer fiber context, a
     finalizers ref, or a try/with frame. Effect-v4 has the same
     short-circuit (`if (effectIsExit(effect)) return effect`); without
     it, [Runtime.run rt (Effect.pure 0)] pays ~140 ns/call for fiber
     setup it never uses. With it, the same call is ~2 ns. The view
     cast itself is [%identity] (zero cost). *)
  match EV.view eff with
  | EV.Pure v -> Exit.Ok v
  | EV.Fail e -> Exit.Error (Cause.Fail e)
  | _ ->
      Tracer.with_fiber_context @@ fun () ->
      Eio.Switch.run @@ fun sw ->
      let finalizers = ref [] in
      try
        Exit.Ok
          (with_finalizers ~runtime:t ~fail_key:t.default_fail_key finalizers
             (fun () ->
               interpret ~runtime:t ~error_renderer:RObs.default_error_renderer
                 ~fail_key:t.default_fail_key ~sw ~finalizers eff))
      with exn -> Exit.Error (cause_of_exn_runtime t t.default_fail_key exn)

let run_exn t eff =
  match run t eff with
  | Exit.Ok value -> value
  | Exit.Error (Cause.Die { exn; backtrace = Some backtrace; _ }) ->
      Printexc.raise_with_backtrace exn backtrace
  | Exit.Error (Cause.Die { exn; backtrace = None; _ }) -> raise exn
  | Exit.Error _ -> failwith "Eta.Runtime.run_exn"

let drain t =
  while P_atomic.get t.active > 0 do
    Eio.Fiber.yield ()
  done
