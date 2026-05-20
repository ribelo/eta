module E = Effect
module EP = Effect.Private
module Sch = Schedule

exception Raised_cause of int * Obj.t

let active_span_key : int Eio.Fiber.key = Eio.Fiber.create_key ()
let sampled_key : bool Eio.Fiber.key = Eio.Fiber.create_key ()
let trace_context_key : Capabilities.trace_context Eio.Fiber.key =
  Eio.Fiber.create_key ()

type die_context = {
  span_name : string option;
  annotations : (string * string) list;
}

let die_context_key : die_context Eio.Fiber.key = Eio.Fiber.create_key ()
let empty_die_context = { span_name = None; annotations = [] }
let current_die_context () =
  Option.value (Eio.Fiber.get die_context_key) ~default:empty_die_context

let with_die_span_name name f =
  let context = current_die_context () in
  Eio.Fiber.with_binding die_context_key { context with span_name = Some name } f

let with_die_annotation key value f =
  let context = current_die_context () in
  let annotations = context.annotations @ [ (key, value) ] in
  Eio.Fiber.with_binding die_context_key { context with annotations } f

module Typed_fail : sig
  type key

  val fresh : unit -> key
  val int : key -> int
end = struct
  type key = int
  let counter = ref 0
  let fresh () = incr counter; !counter
  let int key = key
end

let raise_cause key cause =
  raise (Raised_cause (Typed_fail.int key, Obj.repr cause))

let raise_fail key err = raise_cause key (Cause.Fail err)

let die_of_exn ?backtrace ~capture_backtrace exn =
  let backtrace =
    if capture_backtrace then
      match backtrace with
      | Some _ as bt -> bt
      | None -> Some (Printexc.get_raw_backtrace ())
    else None
  in
  let context = current_die_context () in
  Cause.die_with_diagnostics ?backtrace ?span_name:context.span_name
    ~annotations:context.annotations exn

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
  | exn -> die_of_exn ?backtrace ~capture_backtrace exn

type ('env, 'err) t = {
  env : 'env;
  sleep : Duration.t -> unit;
  now_ms : unit -> int;
  tracer : Capabilities.tracer;
  sampler : Sampler.t;
  auto_instrument : bool;
  logger : Capabilities.logger;
  meter : Capabilities.meter;
  capture_backtrace : bool;
  cause_pp : Obj.t -> string;
  outer_sw : Eio.Switch.t;
  active : int Atomic.t;
  default_fail_key : Typed_fail.key;
}

let default_cause_pp (obj : Obj.t) : string =
  if Obj.is_int obj then
    (* Polymorphic-variant constant: a single int hash of the tag. *)
    Printf.sprintf "variant#%d" (Obj.obj obj : int)
  else if Obj.tag obj = 0 && Obj.size obj >= 1 && Obj.is_int (Obj.field obj 0)
  then
    (* Polymorphic-variant block: (hash, payload). *)
    Printf.sprintf "variant#%d" (Obj.obj (Obj.field obj 0) : int)
  else "<error>"

let create ~sw ~clock ?sleep ?(tracer = Tracer.noop)
    ?(sampler = Sampler.always_on) ?(auto_instrument = false)
    ?(logger = Logger.noop) ?(meter = Meter.noop) ?(capture_backtrace = true)
    ?cause_pp ~env () =
  let clock = (clock :> float Eio.Time.clock_ty Eio.Std.r) in
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
  let cause_pp = Option.value cause_pp ~default:default_cause_pp in
  {
    env;
    sleep;
    now_ms;
    tracer;
    sampler;
    auto_instrument;
    logger;
    meter;
    capture_backtrace;
    cause_pp;
    outer_sw = sw;
    active = Atomic.make 0;
    default_fail_key = Typed_fail.fresh ();
  }

let rec status_of_cause :
    type err.
    cause_pp:(Obj.t -> string) ->
    err Cause.t ->
    Capabilities.span_status =
 fun ~cause_pp -> function
  | Cause.Fail err -> Error (cause_pp (Obj.repr err))
  | Cause.Die die -> Error (Printexc.to_string die.exn)
  | Cause.Interrupt _ -> Cancelled
  | Cause.Sequential causes | Cause.Concurrent causes ->
      if List.for_all Cause.is_interrupt_only causes then Cancelled
      else
        let render c =
          match status_of_cause ~cause_pp c with
          | Capabilities.Error msg -> msg
          | Capabilities.Cancelled -> "cancelled"
          | Capabilities.Ok -> "ok"
        in
        Error (String.concat " | " (List.map render causes))
  | Cause.Suppressed { primary; finalizer } ->
      let render c =
        match status_of_cause ~cause_pp c with
        | Capabilities.Error msg -> msg
        | Capabilities.Cancelled -> "cancelled"
        | Capabilities.Ok -> "ok"
      in
      Error
        ("primary: " ^ render primary ^ " | suppressed finalizer: "
       ^ render finalizer)

let render_cause ~cause_pp cause =
  match status_of_cause ~cause_pp cause with
  | Capabilities.Error msg -> msg
  | Capabilities.Cancelled -> "cancelled"
  | Capabilities.Ok -> "ok"

let exception_event_attrs ~cause_pp path cause =
  let base =
    [
      ("exception.message", render_cause ~cause_pp cause);
      ("effet.cause.path", path);
    ]
  in
  match cause with
  | Cause.Die die ->
      let with_type = ("exception.type", Printexc.to_string die.exn) :: base in
      let with_stack =
        match die.backtrace with
        | None -> with_type
        | Some bt ->
            ("exception.stacktrace", Printexc.raw_backtrace_to_string bt)
            :: with_type
      in
      let with_span =
        match die.span_name with
        | None -> with_stack
        | Some name -> ("effet.die.span_name", name) :: with_stack
      in
      List.map
        (fun (key, value) -> ("effet.annotation." ^ key, value))
        die.annotations
      @ with_span
  | Cause.Fail _ | Cause.Interrupt _ -> base
  | Cause.Sequential _ | Cause.Concurrent _ | Cause.Suppressed _ -> assert false

let exception_event_attrs_tree ~cause_pp cause =
  let rec collect path acc = function
    | Cause.Fail _ | Cause.Die _ | Cause.Interrupt _ as c ->
        exception_event_attrs ~cause_pp path c :: acc
    | Cause.Sequential causes ->
        causes
        |> List.mapi (fun i c -> (i, c))
        |> List.fold_left
             (fun acc (i, c) ->
               collect (path ^ ".seq." ^ string_of_int i) acc c)
             acc
    | Cause.Concurrent causes ->
        causes
        |> List.mapi (fun i c -> (i, c))
        |> List.fold_left
             (fun acc (i, c) ->
               collect (path ^ ".concurrent." ^ string_of_int i) acc c)
             acc
    | Cause.Suppressed { primary; finalizer } ->
        let acc = collect (path ^ ".primary") acc primary in
        collect (path ^ ".suppressed_finalizer") acc finalizer
  in
  List.rev (collect "cause" [] cause)

let cause_of_exn_runtime runtime key exn =
  cause_of_exn ~capture_backtrace:runtime.capture_backtrace key exn

let die_of_exn_runtime runtime exn =
  die_of_exn ~capture_backtrace:runtime.capture_backtrace exn

let run_finalizers ~runtime ~fail_key finalizers =
  Eio.Cancel.protect @@ fun () ->
  match !finalizers with
  | [] -> None
  | fs ->
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
    type re env err a.
    runtime:(re, _) t ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (env, err, a) E.t ->
    env ->
    a =
 fun ~runtime ~fail_key ~sw ~finalizers eff env ->
  match EP.view eff with
  | EP.Pure v -> v
  | EP.Fail e -> raise_fail fail_key e
  | EP.Thunk (name, f) ->
      if runtime.auto_instrument then
        instrument_leaf ~runtime ~fail_key ~name (fun () -> f env)
      else f env
  | EP.Bind (e, k) ->
      let v = interpret ~runtime ~fail_key ~sw ~finalizers e env in
      interpret ~runtime ~fail_key ~sw ~finalizers (k v) env
  | EP.Map (e, f) -> f (interpret ~runtime ~fail_key ~sw ~finalizers e env)
  | EP.Catch (e, handler) ->
      let inner_key = Typed_fail.fresh () in
      (try interpret ~runtime ~fail_key:inner_key ~sw ~finalizers e env with
      | Raised_cause (k, cause) when k = Typed_fail.int inner_key -> (
          match Obj.obj cause with
          | Cause.Fail err ->
              interpret ~runtime ~fail_key ~sw ~finalizers (handler err) env
          | cause -> raise_cause fail_key cause)
      | Eio.Cancel.Cancelled _ -> raise_cause fail_key Cause.interrupt
      | exn -> raise_cause fail_key (die_of_exn_runtime runtime exn))
  | EP.Tap_error (e, observe) ->
      let inner_key = Typed_fail.fresh () in
      (try interpret ~runtime ~fail_key:inner_key ~sw ~finalizers e env with
      | Raised_cause (k, cause) when k = Typed_fail.int inner_key -> (
          match Obj.obj cause with
          | Cause.Fail err ->
              observe err;
              raise_fail fail_key err
          | cause -> raise_cause fail_key cause)
      | Eio.Cancel.Cancelled _ -> raise_cause fail_key Cause.interrupt
      | exn -> raise_cause fail_key (die_of_exn_runtime runtime exn))
  | EP.Delay (d, e) ->
      runtime.sleep d;
      interpret ~runtime ~fail_key ~sw ~finalizers e env
  | EP.Timeout (d, e) ->
      Eio.Fiber.first
        (fun () ->
          runtime.sleep d;
          raise_fail fail_key `Timeout)
        (fun () -> interpret ~runtime ~fail_key ~sw ~finalizers e env)
  | EP.Concat children ->
      List.iter
        (fun child ->
          let () = interpret ~runtime ~fail_key ~sw ~finalizers child env in
          ())
        children
  | EP.Race children -> race_first ~runtime ~fail_key ~finalizers children env
  | EP.Par (a, b) ->
      let tasks : (env -> Obj.t) list =
        [
          (fun env ->
            Obj.repr
              (interpret ~runtime ~fail_key ~sw ~finalizers a env));
          (fun env ->
            Obj.repr
              (interpret ~runtime ~fail_key ~sw ~finalizers b env));
        ]
      in
      (match
         par_collect ~runtime ~fail_key ~finalizers tasks env
       with
       | [ va; vb ] -> (Obj.obj va, Obj.obj vb)
       | _ -> assert false)
  | EP.All children ->
      par_collect ~runtime ~fail_key ~finalizers
        (List.map
           (fun child env ->
             interpret ~runtime ~fail_key ~sw ~finalizers child env)
           children)
        env
  | EP.All_settled children ->
      par_collect_settled ~runtime ~fail_key ~finalizers children env
  | EP.For_each_par (xs, f) ->
      par_collect ~runtime ~fail_key ~finalizers
        (List.map
           (fun x env ->
             interpret ~runtime ~fail_key ~sw ~finalizers (f x) env)
           xs)
        env
  | EP.For_each_par_bounded (max, xs, f) ->
      let semaphore = Eio.Semaphore.make max in
      par_collect ~runtime ~fail_key ~finalizers
        (List.map
           (fun x env ->
             Eio.Semaphore.acquire semaphore;
             Fun.protect
               ~finally:(fun () -> Eio.Semaphore.release semaphore)
               (fun () ->
                 interpret ~runtime ~fail_key ~sw ~finalizers (f x) env))
           xs)
        env
  | EP.Daemon e -> daemon_effect ~runtime e env
  | EP.Uninterruptible e ->
      Eio.Cancel.protect (fun () ->
          interpret ~runtime ~fail_key ~sw ~finalizers e env)
  | EP.Repeat (e, schedule) ->
      repeat_eff ~runtime ~fail_key ~sw ~finalizers e schedule env
  | EP.Retry (e, schedule, predicate) ->
      retry_eff ~runtime ~fail_key ~sw ~finalizers e schedule predicate env
  | EP.Acquire_release (acquire, release) ->
      let v = interpret ~runtime ~fail_key ~sw ~finalizers acquire env in
      finalizers :=
        (fun () ->
          let release_finalizers = ref [] in
          with_finalizers ~runtime ~fail_key release_finalizers (fun () ->
              interpret ~runtime ~fail_key ~sw ~finalizers:release_finalizers
                (release v) env))
        :: !finalizers;
      v
  | EP.Scoped e ->
      Eio.Switch.run @@ fun sw' ->
      let child_finalizers = ref [] in
      with_finalizers ~runtime ~fail_key child_finalizers (fun () ->
          interpret ~runtime ~fail_key ~sw:sw' ~finalizers:child_finalizers e env)
  | EP.Supervisor_scoped (max_failures, body) ->
      Eio.Switch.run @@ fun supervisor_sw ->
      let supervisor =
        EP.make_supervisor ~sw:supervisor_sw ~max_failures
      in
      let supervisor_finalizers = ref [] in
      with_finalizers ~runtime ~fail_key supervisor_finalizers (fun () ->
          interpret_supervisor_scope ~runtime ~fail_key ~sw:supervisor_sw
            ~finalizers:supervisor_finalizers (body.run supervisor) env)
  | EP.Named (kind, name, e) ->
      let parent_id = Eio.Fiber.get active_span_key in
      let ambient_context = Eio.Fiber.get trace_context_key in
      let parent_sampled =
        Option.value (Eio.Fiber.get sampled_key)
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
        && runtime.sampler.sample ~trace_id:"" ~name ~attrs:[]
             ~parent:(Option.is_some parent_id || Option.is_some ambient_context)
      in
      if not sampled then
        with_die_span_name name @@ fun () ->
        Eio.Fiber.with_binding sampled_key false @@ fun () ->
        (try interpret ~runtime ~fail_key ~sw ~finalizers e env with exn ->
           raise_cause fail_key (cause_of_exn_runtime runtime fail_key exn))
      else
        let started_ms = runtime.now_ms () in
        let span_id =
          runtime.tracer#begin_span ?parent_id ?external_parent ~name
            ~kind ~started_ms ()
        in
        let finish status =
          let ended_ms = runtime.now_ms () in
          runtime.tracer#end_span ~span_id ~status ~ended_ms
        in
        let emit_exception_event cause =
          let events =
            exception_event_attrs_tree ~cause_pp:runtime.cause_pp cause
          in
          List.iter
            (fun attrs ->
              runtime.tracer#add_event ~span_id ~name:"exception"
                ~ts_ms:(runtime.now_ms ()) ~attrs)
            events
        in
        with_die_span_name name @@ fun () ->
        Eio.Fiber.with_binding active_span_key span_id @@ fun () ->
        Eio.Fiber.with_binding sampled_key true @@ fun () ->
        (try
           let value = interpret ~runtime ~fail_key ~sw ~finalizers e env in
           finish Ok;
           value
         with exn ->
           let cause = cause_of_exn_runtime runtime fail_key exn in
           emit_exception_event cause;
           finish (status_of_cause ~cause_pp:runtime.cause_pp cause);
           raise_cause fail_key cause)
  | EP.Annotate (key, value, e) ->
      runtime.tracer#add_attr ~key ~value;
      with_die_annotation key value @@ fun () ->
      (try interpret ~runtime ~fail_key ~sw ~finalizers e env with exn ->
         raise_cause fail_key (cause_of_exn_runtime runtime fail_key exn))
  | EP.Link_span (link, e) ->
      runtime.tracer#add_link link;
      interpret ~runtime ~fail_key ~sw ~finalizers e env
  | EP.With_external_parent (ctx, e) | EP.With_context (ctx, e) ->
      Eio.Fiber.with_binding trace_context_key ctx @@ fun () ->
      Eio.Fiber.with_binding sampled_key (Trace_context.sampled ctx) @@ fun () ->
      interpret ~runtime ~fail_key ~sw ~finalizers e env
  | EP.Current_span -> (
      match Eio.Fiber.get active_span_key with
      | None -> None
      | Some span_id -> runtime.tracer#inspect ~span_id)
  | EP.Current_context -> (
      match Eio.Fiber.get active_span_key with
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
          | None -> Eio.Fiber.get trace_context_key)
      | None -> Eio.Fiber.get trace_context_key)
  | EP.Log (level, body, attrs) ->
      let trace_id, span_id =
        match Eio.Fiber.get active_span_key with
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
        }
  | EP.Metric_update { name; description; unit_; kind; attrs; value } ->
      runtime.meter#record ~name ~description ~unit_ ~kind ~attrs ~value
        ~ts_ms:(runtime.now_ms ())

and instrument_leaf :
    type re err a.
    runtime:(re, _) t -> fail_key:Typed_fail.key -> name:string -> (unit -> a) -> a
    =
 fun ~runtime ~fail_key ~name f ->
  let parent_id = Eio.Fiber.get active_span_key in
  let ambient_context = Eio.Fiber.get trace_context_key in
  let parent_sampled =
    Option.value (Eio.Fiber.get sampled_key)
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
    && runtime.sampler.sample ~trace_id:"" ~name ~attrs:[]
         ~parent:(Option.is_some parent_id || Option.is_some ambient_context)
  in
  if not sampled then
    with_die_span_name name @@ fun () ->
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
    with_die_span_name name @@ fun () ->
    Eio.Fiber.with_binding active_span_key span_id @@ fun () ->
    Eio.Fiber.with_binding sampled_key true @@ fun () ->
    try
      let value = f () in
      finish Ok;
      value
    with exn ->
      let cause = cause_of_exn_runtime runtime fail_key exn in
      exception_event_attrs_tree ~cause_pp:runtime.cause_pp cause
      |> List.iter (fun attrs ->
             runtime.tracer#add_event ~span_id ~name:"exception"
               ~ts_ms:(runtime.now_ms ()) ~attrs);
      finish (status_of_cause ~cause_pp:runtime.cause_pp cause);
      raise_cause fail_key cause

and interpret_supervisor_scope :
    type re s env err a.
    runtime:(re, _) t ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (s, env, err, a) E.supervisor_scope ->
    env ->
    a =
 fun ~runtime ~fail_key ~sw ~finalizers eff env ->
  match eff with
  | E.Supervisor_pure value -> value
  | E.Supervisor_lift child_effect ->
      interpret ~runtime ~fail_key ~sw ~finalizers child_effect env
  | E.Supervisor_fail err -> raise_fail fail_key err
  | E.Supervisor_bind (scope_effect, k) ->
      let value =
        interpret_supervisor_scope ~runtime ~fail_key ~sw ~finalizers scope_effect
          env
      in
      interpret_supervisor_scope ~runtime ~fail_key ~sw ~finalizers (k value) env
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
      Eio.Fiber.fork ~sw:(E.Private.supervisor_switch supervisor) (fun () ->
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
                     interpret_supervisor_scope ~runtime ~fail_key
                       ~sw:child_switch ~finalizers:child_finalizers child_effect
                       env))
            with exn -> Error (cause_of_exn_runtime runtime fail_key exn)
          in
          (match result with
          | Ok _ -> ()
          | Error cause ->
              let failures = E.Private.supervisor_failures_ref supervisor in
              failures := cause :: !failures);
          resolve result);
      E.Private.make_supervisor_child ~promise
        ~cancel:
          (fun () ->
            Atomic.set cancel_requested true;
            match !child_cancel with
            | None -> resolve (Error Cause.interrupt)
            | Some cancel_context ->
                Eio.Cancel.cancel cancel_context Exit;
                (match !child_sw with
                | None -> ()
                | Some child_switch ->
                    (try Eio.Switch.fail child_switch Exit with _ -> ())))
  | E.Supervisor_await child -> (
      match Eio.Promise.await (E.Private.supervisor_child_promise child) with
      | Ok value -> value
      | Error cause -> raise_cause fail_key cause)
  | E.Supervisor_cancel child ->
      E.Private.supervisor_child_cancel child ()
  | E.Supervisor_failures supervisor ->
      List.rev !(E.Private.supervisor_failures_ref supervisor)
  | E.Supervisor_check supervisor -> (
      match E.Private.supervisor_max_failures supervisor with
      | None -> ()
      | Some max ->
          let count =
            List.length !(E.Private.supervisor_failures_ref supervisor)
          in
          if count >= max then raise_fail fail_key (`Supervisor_failed count))
  | E.Supervisor_yield -> Eio.Fiber.yield ()

and par_collect :
    type re env err a.
    runtime:(re, _) t ->
    fail_key:Typed_fail.key ->
    finalizers:(unit -> unit) list ref ->
    (env -> a) list ->
    env ->
    a list =
	 fun ~runtime ~fail_key ~finalizers:_ tasks env ->
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
             try results.(i) <- Some (task env)
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
    type re env err a.
    runtime:(re, _) t ->
    fail_key:Typed_fail.key ->
    finalizers:(unit -> unit) list ref ->
    (env, err, a) E.t list ->
    env ->
    a =
 fun ~runtime ~fail_key ~finalizers children env ->
  match children with
  | [] -> failwith "Effect.race: empty list"
  | _ ->
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
                    interpret ~runtime ~fail_key ~sw:race_sw ~finalizers child
                      env
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
    type re env err a.
    runtime:(re, _) t ->
    fail_key:Typed_fail.key ->
    finalizers:(unit -> unit) list ref ->
    (env, err, a) E.t list ->
    env ->
    (a, err Cause.t) result list =
 fun ~runtime ~fail_key ~finalizers children env ->
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
                    (interpret ~runtime ~fail_key ~sw:par_sw ~finalizers child
                       env)
                with exn ->
                  Error (cause_of_exn_runtime runtime fail_key exn))))
     children);
  Array.to_list results |> List.map Option.get

and daemon_effect :
    type re env err.
    runtime:(re, _) t -> (env, err, unit) E.t -> env -> unit =
 fun ~runtime eff env -> fork_internal ~runtime eff env

and fork_internal :
    type re env err.
    runtime:(re, _) t -> (env, err, unit) E.t -> env -> unit =
 fun ~runtime eff env ->
  Atomic.incr runtime.active;
  Eio.Fiber.fork_daemon ~sw:runtime.outer_sw (fun () ->
      Tracer.with_fiber_context @@ fun () ->
      Fun.protect
        ~finally:(fun () -> Atomic.decr runtime.active)
        (fun () ->
          (try
             Eio.Switch.run @@ fun sw' ->
             interpret ~runtime ~fail_key:runtime.default_fail_key ~sw:sw'
               ~finalizers:(ref []) eff env
           with _ -> ());
          `Stop_daemon))

and repeat_eff :
    type re env err.
    runtime:(re, _) t ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (env, err, unit) E.t ->
    Sch.t ->
    env ->
    unit =
 fun ~runtime ~fail_key ~sw ~finalizers e schedule env ->
  interpret ~runtime ~fail_key ~sw ~finalizers e env;
  let step = ref 0 in
  let continue = ref true in
  while !continue do
    match Sch.next_delay schedule ~step:!step with
    | None -> continue := false
    | Some d ->
        runtime.sleep d;
        interpret ~runtime ~fail_key ~sw ~finalizers e env;
        incr step
  done

and retry_eff :
    type re env err a.
    runtime:(re, _) t ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (env, err, a) E.t ->
    Sch.t ->
    (err -> bool) ->
    env ->
    a =
 fun ~runtime ~fail_key ~sw ~finalizers e schedule predicate env ->
  let attempt_key = Typed_fail.fresh () in
  let step = ref 0 in
  let result : a option ref = ref None in
  while Option.is_none !result do
    (try
       let v =
         interpret ~runtime ~fail_key:attempt_key ~sw ~finalizers e env
       in
       result := Some v
     with
     | Raised_cause (k, cause) when k = Typed_fail.int attempt_key -> (
         match Obj.obj cause with
         | Cause.Fail err ->
             if predicate err then
               match Sch.next_delay schedule ~step:!step with
               | Some d ->
                   runtime.sleep d;
                   incr step
               | None -> raise_fail fail_key err
             else raise_fail fail_key err
         | cause -> raise_cause fail_key cause)
     | Eio.Cancel.Cancelled _ -> raise_cause fail_key Cause.interrupt
     | exn -> raise_cause fail_key (die_of_exn_runtime runtime exn))
  done;
  Option.get !result

let run t eff =
  Tracer.with_fiber_context @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let finalizers = ref [] in
  try
    Exit.Ok
      (interpret ~runtime:t ~fail_key:t.default_fail_key ~sw ~finalizers eff
         t.env)
  with exn -> Exit.Error (cause_of_exn_runtime t t.default_fail_key exn)

let run_exn t eff =
  match run t eff with
  | Exit.Ok value -> value
  | Exit.Error (Cause.Die { exn; backtrace = Some backtrace; _ }) ->
      Printexc.raise_with_backtrace exn backtrace
  | Exit.Error (Cause.Die { exn; backtrace = None; _ }) -> raise exn
  | Exit.Error _ -> failwith "Effet.Runtime.run_exn"

let drain t =
  while Atomic.get t.active > 0 do
    Eio.Fiber.yield ()
  done
