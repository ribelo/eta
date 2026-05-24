open Runtime_core
module E = Effect
module EV = Effect_ast
module RObs = Runtime_observability
module Sch = Schedule

external view : ('a, 'err) E.t -> ('a, 'err) EV.t = "%identity"
external effect : ('a, 'err) EV.t -> ('a, 'err) E.t = "%identity"

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
  match view eff with
  (* Terminal and offloaded leaves. *)
  | EV.Pure v -> v
  | EV.Fail e -> raise_fail fail_key e
  | EV.Sync f -> f ()
  | EV.Island { name; f; input } ->
      let run () = Island_runtime.submit name (island_pool runtime None) f input in
      if runtime.auto_instrument then
        Runtime_instrument.instrument_leaf ~runtime ~error_renderer ~fail_key
          ~name run
      else run ()
  | EV.Island_map { name; pool; f; inputs } ->
      let run () =
        Island_runtime.submit_map name (island_pool runtime pool) f inputs
      in
      if runtime.auto_instrument then
        Runtime_instrument.instrument_leaf ~runtime ~error_renderer ~fail_key
          ~name run
      else run ()
  | EV.Island_map_result { name; pool; f; inputs } ->
      let run () =
        Island_runtime.submit_map_result name (island_pool runtime pool) f inputs
      in
      if runtime.auto_instrument then
        Runtime_instrument.instrument_leaf ~runtime ~error_renderer ~fail_key
          ~name run
      else run ()
  | EV.Island_all_settled { name; pool; f; inputs } ->
      let run () =
        Island_runtime.submit_all_settled (island_pool runtime pool) f inputs
      in
      if runtime.auto_instrument then
        Runtime_instrument.instrument_leaf ~runtime ~error_renderer ~fail_key
          ~name run
      else run ()
  | EV.Blocking { name; pool; f } ->
      let run () =
        Blocking_runtime.submit ~sw:runtime.outer_sw
          ~emit:(emit_blocking_event runtime) (blocking_pool runtime pool) name f
      in
      if runtime.auto_instrument then
        Runtime_instrument.instrument_leaf ~runtime ~error_renderer ~fail_key
          ~name run
      else run ()
  (* Sequential composition and typed failure handling. *)
  | EV.Bind (e, k) ->
      let v =
        interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
      in
      interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers (k v)
  | EV.Map (e, f) ->
      f (interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers e)
  | EV.Catch (e, handler) ->
      let inner_key = Typed_fail.fresh () in
      (try
         interpret_ast ~runtime ~error_renderer:RObs.default_error_renderer
           ~fail_key:inner_key ~sw ~finalizers e
       with
      | Raised_cause (k, cause) when k = Typed_fail.int inner_key -> (
          match Obj.obj cause with
          | Cause.Fail err ->
              interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers
                (handler err)
          | cause -> raise_cause fail_key cause)
      | Eio.Cancel.Cancelled _ -> raise_cause fail_key Cause.interrupt
      | exn -> raise_cause fail_key (cause_of_exn_runtime runtime inner_key exn))
  | EV.Tap_error (e, observe) ->
      let inner_key = Typed_fail.fresh () in
      (try
         interpret_ast ~runtime ~error_renderer ~fail_key:inner_key ~sw
           ~finalizers e
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
  (* Time and scheduling. *)
  | EV.Delay (d, e) ->
      runtime.sleep d;
      interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
  | EV.Timeout (d, e) ->
      let token = Typed_fail.int (Typed_fail.fresh ()) in
      (try
         Eio.Fiber.first
           (fun () ->
             runtime.sleep d;
             raise (Timeout_as_fired token))
           (fun () ->
             interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers e)
       with exn ->
         if
           has_timeout_as token exn
           && only_timeout_as_or_interrupt token exn
         then
           raise_fail fail_key `Timeout
         else
           raise_cause fail_key
             (cause_of_timeout_as_exn runtime fail_key token `Timeout exn))
  | EV.Timeout_as (d, on_timeout, e) ->
      let token = Typed_fail.int (Typed_fail.fresh ()) in
      (try
         Eio.Fiber.first
           (fun () ->
             runtime.sleep d;
             raise (Timeout_as_fired token))
           (fun () ->
             interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers e)
       with exn ->
         if
           has_timeout_as token exn
           && only_timeout_as_or_interrupt token exn
         then raise_fail fail_key on_timeout
         else
           raise_cause fail_key
             (cause_of_timeout_as_exn runtime fail_key token on_timeout exn))
  (* Concurrent combinators. *)
  | EV.Concat children ->
      List.iter
        (fun child ->
          let () =
            interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers
              child
          in
          ())
        children
  | EV.Race children ->
      Runtime_concurrency.race_first ~runtime ~interpret_ast ~error_renderer
        ~fail_key ~finalizers children
  | EV.Par (a, b) ->
      (* [par_collect] needs a homogeneous task list, while [Effect.par] returns
         a heterogeneous pair. These casts are slot-local: each packed result is
         unpacked exactly at the slot whose task produced it. *)
      let tasks : (unit -> Obj.t) list =
        [
          (fun () ->
            Obj.repr
              (interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers
                 a));
          (fun () ->
            Obj.repr
              (interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers
                 b));
        ]
      in
      (match
         Runtime_concurrency.par_collect ~runtime ~fail_key ~finalizers tasks
       with
       | [ va; vb ] -> (Obj.obj va, Obj.obj vb)
       | _ -> assert false)
  | EV.All children ->
      Runtime_concurrency.par_collect ~runtime ~fail_key ~finalizers
        (List.map
           (fun child () ->
             interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers
               child)
           children)
  | EV.All_settled children ->
      Runtime_concurrency.par_collect_settled ~runtime ~interpret_ast
        ~error_renderer:RObs.default_error_renderer ~fail_key ~finalizers
        children
  | EV.For_each_par (xs, f) ->
      Runtime_concurrency.par_collect ~runtime ~fail_key ~finalizers
        (List.map
           (fun x () ->
             interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers
               (f x))
           xs)
  | EV.For_each_par_bounded (max, xs, f) ->
      let semaphore = Eio.Semaphore.make max in
      Runtime_concurrency.par_collect ~runtime ~fail_key ~finalizers
        (List.map
           (fun x () ->
             Eio.Semaphore.acquire semaphore;
             Fun.protect
               ~finally:(fun () -> Eio.Semaphore.release semaphore)
               (fun () ->
                 interpret_ast ~runtime ~error_renderer ~fail_key ~sw
                   ~finalizers (f x)))
           xs)
  | EV.Daemon e -> Runtime_concurrency.fork_internal ~runtime ~interpret_ast e
  | EV.Uninterruptible e ->
      Eio.Cancel.protect (fun () ->
          interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers e)
  (* Resource scopes and supervision. *)
  | EV.Repeat (e, schedule) ->
      repeat_eff ~runtime ~error_renderer ~fail_key ~sw ~finalizers e schedule
  | EV.Retry (e, schedule, predicate) ->
      retry_eff ~runtime ~error_renderer ~fail_key ~sw ~finalizers e schedule
        predicate
  | EV.Acquire_release (acquire, release) ->
      let v =
        interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers acquire
      in
      finalizers :=
        (fun () ->
          let release_finalizers = ref [] in
          with_finalizers ~runtime ~fail_key release_finalizers (fun () ->
              interpret_ast ~runtime ~error_renderer ~fail_key ~sw
                ~finalizers:release_finalizers (release v)))
        :: !finalizers;
      v
  | EV.Scoped e ->
      Eio.Switch.run @@ fun sw' ->
      let child_finalizers = ref [] in
      with_finalizers ~runtime ~fail_key child_finalizers (fun () ->
          interpret_ast ~runtime ~error_renderer ~fail_key ~sw:sw'
            ~finalizers:child_finalizers e)
  | EV.Supervisor_scoped (max_failures, body) ->
      Eio.Switch.run @@ fun supervisor_sw ->
      let supervisor =
        Runtime_supervisor.make ~sw:supervisor_sw ~max_failures
      in
      let supervisor_finalizers = ref [] in
      with_finalizers ~runtime ~fail_key supervisor_finalizers (fun () ->
          Fun.protect
            ~finally:(fun () -> Runtime_supervisor.cancel_children supervisor)
            (fun () ->
              let module Supervisor = Runtime_supervisor.Make (struct
                let interpret_ast :
                    type a err.
                    error_renderer:(err -> string) ->
                    fail_key:Typed_fail.key ->
                    sw:Eio.Switch.t ->
                    finalizers:(unit -> unit) list ref ->
                    (a, err) EV.t ->
                    a =
                 fun ~error_renderer ~fail_key ~sw ~finalizers eff ->
                  interpret_ast ~runtime ~error_renderer ~fail_key ~sw
                    ~finalizers eff
              end) in
              Supervisor.interpret_scope ~runtime ~error_renderer ~fail_key
                ~sw:supervisor_sw ~finalizers:supervisor_finalizers
                (body.run supervisor)))
  (* Observability and runtime capabilities. *)
  | EV.Render_error (render, e) ->
      interpret_ast ~runtime ~error_renderer:render ~fail_key ~sw ~finalizers e
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
      interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
  | EV.Named (kind, name, e) ->
      Runtime_instrument.interpret_named ~runtime ~interpret_ast
        ~error_renderer ~fail_key ~sw ~finalizers ~kind ~name ~attrs:[] e
  | EV.Named_attrs (kind, name, attrs, e) ->
      Runtime_instrument.interpret_named ~runtime ~interpret_ast
        ~error_renderer ~fail_key ~sw ~finalizers ~kind ~name ~attrs e
  | EV.Annotate (key, value, e) ->
      (if runtime.tracing_enabled then
         match Eio.Fiber.get RObs.active_span_key with
         | Some span_id -> runtime.tracer#add_attr_to ~span_id ~key ~value
         | None -> runtime.tracer#add_attr ~key ~value);
      RObs.with_die_annotation key value @@ fun () ->
      (try
         interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
       with exn ->
         raise_cause fail_key (cause_of_exn_runtime runtime fail_key exn))
  | EV.Link_span (link, e) ->
      (if runtime.tracing_enabled then
         match Eio.Fiber.get RObs.active_span_key with
         | Some span_id -> runtime.tracer#add_link_to ~span_id link
         | None -> runtime.tracer#add_link link);
      interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
  | EV.With_external_parent (ctx, e) | EV.With_context (ctx, e) ->
      if runtime.tracing_enabled then
        Eio.Fiber.with_binding RObs.trace_context_key ctx @@ fun () ->
        Eio.Fiber.with_binding RObs.sampled_key (Trace_context.sampled ctx) @@ fun () ->
        interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
      else
        Eio.Fiber.with_binding RObs.trace_context_key ctx @@ fun () ->
        interpret_ast ~runtime ~error_renderer ~fail_key ~sw ~finalizers e
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

and repeat_eff :
    type err.
    runtime:_ t ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (unit, err) EV.t ->
    Sch.t ->
    unit =
 fun ~runtime ~error_renderer ~fail_key ~sw ~finalizers e schedule ->
  let run_iteration () =
    let iteration_finalizers = ref [] in
    with_finalizers ~runtime ~fail_key iteration_finalizers (fun () ->
        interpret_ast ~runtime ~error_renderer ~fail_key ~sw
          ~finalizers:iteration_finalizers e)
  in
  run_iteration ();
  let driver = ref (Sch.start ~random:runtime.random schedule) in
  let continue = ref true in
  while !continue do
    match Sch.next !driver with
    | None -> continue := false
    | Some (d, next_driver) ->
        driver := next_driver;
        runtime.sleep d;
        run_iteration ()
  done

and retry_eff :
    type err a.
    runtime:_ t ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (a, err) EV.t ->
    Sch.t ->
    (err -> bool) ->
    a =
 fun ~runtime ~error_renderer ~fail_key ~sw ~finalizers e schedule predicate ->
  let attempt_key = Typed_fail.fresh () in
  let driver = ref (Sch.start ~random:runtime.random schedule) in
  let result : a option ref = ref None in
  while Option.is_none !result do
    let attempt_finalizers = ref [] in
    (try
      let v =
        with_finalizers ~runtime ~fail_key:attempt_key attempt_finalizers
          (fun () ->
            interpret_ast ~runtime ~error_renderer ~fail_key:attempt_key ~sw
              ~finalizers:attempt_finalizers e)
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

and interpret_ast :
    type err a.
    runtime:_ t ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (a, err) EV.t ->
    a =
 fun ~runtime ~error_renderer ~fail_key ~sw ~finalizers eff ->
  interpret ~runtime ~error_renderer ~fail_key ~sw ~finalizers (effect eff)
