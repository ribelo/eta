open Runtime_core

module RObs = Runtime_observability
module Sch = Schedule
module P_atomic = Portable.Atomic

type frame = {
  runtime : Obj.t Runtime_core.t;
  error_renderer : Obj.t -> string;
  fail_key : Runtime_core.Typed_fail.key;
  sw : Eio.Switch.t;
  finalizers : (unit -> unit) list ref;
}

let frame_key : frame Eio.Fiber.key = Eio.Fiber.create_key ()
let fiberless_frame = ref None

let fiber_get key =
  try Eio.Fiber.get key with Stdlib.Effect.Unhandled _ -> None

let host_fiber_get frame key =
  match frame.runtime.host_eio with
  | None -> None
  | Some host -> (
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      try Fiber.get key with Stdlib.Effect.Unhandled _ -> None)

let has_fiber_context () =
  try
    ignore (Eio.Fiber.get frame_key);
    true
  with Stdlib.Effect.Unhandled _ -> false

let current_frame () =
  match fiber_get frame_key with
  | Some frame -> frame
  | None -> (
      match !fiberless_frame with
      | Some frame -> (
          match host_fiber_get frame frame_key with
          | Some frame -> frame
          | None -> frame)
      | None -> failwith "Eta effect requires Runtime.run")

let with_fiberless_frame frame f =
  let previous = !fiberless_frame in
  fiberless_frame := Some frame;
  Fun.protect ~finally:(fun () -> fiberless_frame := previous) f

let with_frame frame f =
  match frame.runtime.host_eio with
  | Some host ->
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      let bind () = Fiber.with_binding frame_key frame f in
      if Option.is_some !fiberless_frame then bind ()
      else with_fiberless_frame frame bind
  | None ->
      if has_fiber_context () then Eio.Fiber.with_binding frame_key frame f
      else with_fiberless_frame frame f

let switch_run frame f =
  match frame.runtime.host_eio with
  | None -> Eio.Switch.run f
  | Some host ->
      let module Switch = (val Host_eio.switch host : Host_eio.SWITCH) in
      Switch.run f

let switch_fail frame sw exn =
  match frame.runtime.host_eio with
  | None -> Eio.Switch.fail sw exn
  | Some host ->
      let module Switch = (val Host_eio.switch host : Host_eio.SWITCH) in
      Switch.fail sw exn

let fiber_first frame left right =
  match frame.runtime.host_eio with
  | None -> Eio.Fiber.first left right
  | Some host ->
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      Fiber.first left right

let fiber_fork frame ~sw f =
  match frame.runtime.host_eio with
  | None -> Eio.Fiber.fork ~sw f
  | Some host ->
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      Fiber.fork ~sw f

let fiber_fork_daemon frame ~sw f =
  match frame.runtime.host_eio with
  | None -> Eio.Fiber.fork_daemon ~sw f
  | Some host ->
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      Fiber.fork_daemon ~sw f

let fiber_await_cancel frame =
  match frame.runtime.host_eio with
  | None -> Eio.Fiber.await_cancel ()
  | Some host ->
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      Fiber.await_cancel ()

let fiber_yield frame =
  match frame.runtime.host_eio with
  | None -> Eio.Fiber.yield ()
  | Some host ->
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      Fiber.yield ()

let cancel_sub frame f =
  match frame.runtime.host_eio with
  | None -> Eio.Cancel.sub f
  | Some host ->
      let module Cancel = (val Host_eio.cancel host : Host_eio.CANCEL) in
      Cancel.sub f

let cancel_cancel frame cancel_context exn =
  match frame.runtime.host_eio with
  | None -> Eio.Cancel.cancel cancel_context exn
  | Some host ->
      let module Cancel = (val Host_eio.cancel host : Host_eio.CANCEL) in
      Cancel.cancel cancel_context exn

let render_error frame err = frame.error_renderer (Obj.repr err)

type ('a, 'err) t = {
  eval : unit -> ('a, 'err) Exit.t;
  leaf_name : string option;
  names : string list;
}

let make ?leaf_name ?(names = []) eval = { eval; leaf_name; names }
let preserve effect eval = make ~names:effect.names eval
let concat_names effects = List.concat_map (fun effect -> effect.names) effects
let with_names names effect = { effect with names }

type ('s, 'a, 'err) supervisor_scope =
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
      ('s, 'err, _) supervisor_child -> ('s, unit, 'err) supervisor_scope
  | Supervisor_failures :
      ('s, 'err) supervisor -> ('s, 'err Cause.t list, _) supervisor_scope
  | Supervisor_check :
      ('s, [> `Supervisor_failed of int ] as 'err) supervisor
      -> ('s, unit, 'err) supervisor_scope
  | Supervisor_yield : ('s, unit, _) supervisor_scope

and ('a, 'err) supervisor_body = {
  run : 's. ('s, 'err) supervisor -> ('s, 'a, 'err) supervisor_scope;
}

and ('s, !'err) supervisor =
  ('s, 'err) Runtime_supervisor_types.supervisor

and ('s, !'err, !'a) supervisor_child =
  ('s, 'err, 'a) Runtime_supervisor_types.child

let ok value = Exit.Ok value
let[@cold][@zero_alloc assume error] error cause = Exit.Error cause
let default_renderer _ = "<typed failure>"

let[@inline always][@zero_alloc opt] exit_to_value frame = function
  | Exit.Ok value -> value
  | Exit.Error cause -> Runtime_core.raise_cause frame.fail_key cause

let[@cold][@zero_alloc assume error] exit_of_exn frame exn =
  Exit.Error (Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn)

let run_to_exit frame effect =
  try with_frame frame effect.eval with exn -> exit_of_exn frame exn

let run_to_value frame effect = exit_to_value frame (run_to_exit frame effect)

let pure value = make (fun () -> ok value)
let fail err = make (fun () -> error (Cause.Fail err))
let unit = pure ()
let from_result = function Stdlib.Ok value -> pure value | Stdlib.Error err -> fail err
let sync f = make (fun () -> try ok (f ()) with exn -> exit_of_exn (current_frame ()) exn)

let map f effect =
  preserve effect @@ fun () ->
  match effect.eval () with
  | Exit.Ok value -> ok (f value)
  | Exit.Error _ as err -> err

let bind k effect =
  preserve effect @@ fun () ->
  match effect.eval () with
  | Exit.Ok value -> (k value).eval ()
  | Exit.Error _ as err -> err

let ( >>= ) effect k = bind k effect
let tap k effect = bind (fun value -> map (fun () -> value) (k value)) effect
let seq next self = bind (fun () -> next) self
let concat effects =
  with_names (concat_names effects)
    (List.fold_left (fun acc effect -> seq effect acc) unit effects)

let catch handler effect =
  preserve effect @@ fun () ->
  match effect.eval () with
  | Exit.Ok _ as ok -> ok
  | Exit.Error (Cause.Fail err) -> (handler err).eval ()
  | Exit.Error cause -> error (Obj.magic cause)

let rec map_cause_error f = function
  | Cause.Fail err -> Cause.Fail (f err)
  | Cause.Die die -> Cause.Die die
  | Cause.Interrupt id -> Cause.Interrupt id
  | Cause.Sequential causes -> Cause.Sequential (List.map (map_cause_error f) causes)
  | Cause.Concurrent causes -> Cause.Concurrent (List.map (map_cause_error f) causes)
  | Cause.Suppressed { primary; finalizer } ->
      Cause.Suppressed
        {
          primary = map_cause_error f primary;
          finalizer = map_cause_error f finalizer;
        }

let map_error f effect =
  preserve effect @@ fun () ->
  match effect.eval () with
  | Exit.Ok _ as ok -> ok
  | Exit.Error cause -> error (map_cause_error f cause)

let tap_error observe effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  match effect.eval () with
  | Exit.Ok _ as ok -> ok
  | Exit.Error (Cause.Fail err) as original -> (
      try
        observe err;
        original
      with exn ->
        let finalizer =
          Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn
        in
        error (Cause.suppressed ~primary:(Cause.Fail err) ~finalizer))
  | Exit.Error _ as err -> err

let delay duration effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  frame.runtime.sleep duration;
  effect.eval ()

let timeout_as duration ~on_timeout effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let token = Runtime_core.Typed_fail.int (Runtime_core.Typed_fail.fresh ()) in
  try
    ok
      (fiber_first frame
         (fun () ->
           frame.runtime.sleep duration;
           raise (Runtime_core.Timeout_as_fired token))
         (fun () -> run_to_value frame effect))
  with exn ->
    if
      Runtime_core.has_timeout_as token exn
      && Runtime_core.only_timeout_as_or_interrupt token exn
    then error (Cause.Fail on_timeout)
    else
      error
        (Runtime_core.cause_of_timeout_as_exn frame.runtime frame.fail_key token
           on_timeout exn)

let timeout duration effect = timeout_as duration ~on_timeout:`Timeout effect

let run_cleanup_to_exit frame cleanup =
  Runtime_core.cancel_protect @@ fun () ->
  let cleanup_finalizers = ref [] in
  let cleanup_frame = { frame with finalizers = cleanup_finalizers } in
  try
    ok
      (Runtime_core.with_finalizers ~runtime:frame.runtime ~fail_key:frame.fail_key
         cleanup_finalizers (fun () -> run_to_value cleanup_frame cleanup))
  with exn -> exit_of_exn cleanup_frame exn

let finally cleanup effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  match run_to_exit frame effect with
  | Exit.Ok value -> (
      match run_cleanup_to_exit frame cleanup with
      | Exit.Ok () -> ok value
      | Exit.Error cause -> error cause)
  | Exit.Error primary -> (
      match run_cleanup_to_exit frame cleanup with
      | Exit.Ok () -> error primary
      | Exit.Error finalizer -> error (Cause.suppressed ~primary ~finalizer))

let run_child frame sw effect =
  let child_frame = { frame with sw } in
  frame.runtime.tracer#with_fiber_context @@ fun () -> run_to_exit child_frame effect

let par_collect frame tasks =
  let n = List.length tasks in
  let results = Array.make n None in
  let causes = ref [] in
  let exception Stop in
  (try
     switch_run frame @@ fun par_sw ->
     List.iteri
       (fun index task ->
         fiber_fork frame ~sw:par_sw (fun () ->
             frame.runtime.tracer#with_fiber_context @@ fun () ->
             try results.(index) <- Some (task ())
             with exn ->
               let cause =
                 Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn
               in
               causes := cause :: !causes;
               (try switch_fail frame par_sw Stop with _ -> ())))
       tasks
   with Stop -> ());
  match List.rev !causes with
  | [] -> ok (Array.to_list results |> List.map Option.get)
  | causes -> error (Cause.concurrent causes)

let race effects () =
  let frame = current_frame () in
  match effects with
  | [] -> invalid_arg "Effect.race: empty list"
  | _ ->
      let winner = ref None in
      let causes = ref [] in
      let exception Race_won in
      (try
         switch_run frame @@ fun race_sw ->
         let results = Eio.Stream.create (List.length effects) in
         List.iter
           (fun effect ->
             fiber_fork frame ~sw:race_sw (fun () ->
                 Eio.Stream.add results (run_child frame race_sw effect)))
           effects;
         let rec collect failed remaining =
           if remaining = 0 then causes := List.rev failed
           else
             match Eio.Stream.take results with
             | Exit.Ok value ->
                 winner := Some (Obj.repr value);
                 switch_fail frame race_sw Race_won;
                 fiber_await_cancel frame
             | Exit.Error cause -> collect (cause :: failed) (remaining - 1)
         in
         collect [] (List.length effects)
       with Race_won -> ());
      (match !winner with
      | Some value -> ok (Obj.obj value)
      | None -> error (Cause.concurrent !causes))

let race effects =
  make ~names:(concat_names effects) (race effects)

let missing_result name = Cause.die (Failure (name ^ ": missing result"))

let par left right () =
  let frame = current_frame () in
  match
    par_collect frame
      [
        (fun () -> Obj.repr (run_to_value frame left));
        (fun () -> Obj.repr (run_to_value frame right));
      ]
  with
  | Exit.Ok [ left; right ] -> ok (Obj.obj left, Obj.obj right)
  | Exit.Ok _ -> assert false
  | Exit.Error cause -> error cause

let par left right =
  make ~names:(left.names @ right.names) (par left right)

let all effects () =
  let frame = current_frame () in
  par_collect frame (List.map (fun effect () -> run_to_value frame effect) effects)

let all effects = make ~names:(concat_names effects) (all effects)

let all_settled effects () =
  let frame = current_frame () in
  let results = Array.make (List.length effects) None in
  switch_run frame (fun sw ->
      List.iteri
        (fun index effect ->
          fiber_fork frame ~sw (fun () ->
              results.(index) <-
                Some
                  (match run_child frame sw effect with
                  | Exit.Ok value -> Ok value
                  | Exit.Error cause -> Error cause)))
        effects);
  ok (Array.to_list results |> List.map Option.get)

let all_settled effects =
  make ~names:(concat_names effects) (all_settled effects)

let for_each_par xs f =
  let n = List.length xs in
  let xs_arr = Array.of_list xs in
  let tasks = Array.map f xs_arr in
  make @@ fun () ->
    let frame = current_frame () in
    let results = Array.make n None in
    let causes = ref [] in
    let next = P_atomic.make 0 in
    let exception Stop in
    let workers = min n 8 in
    let run_task effect =
      exit_to_value frame
        (try effect.eval () with exn -> exit_of_exn frame exn)
    in
    (try
       switch_run frame @@ fun sw ->
       for _ = 1 to workers do
         fiber_fork frame ~sw (fun () ->
             frame.runtime.tracer#with_fiber_context @@ fun () ->
             with_frame frame @@ fun () ->
             try
               let rec loop () =
                 let i = P_atomic.fetch_and_add next 1 in
                 if i < n then begin
                   results.(i) <- Some (run_task (Array.unsafe_get tasks i));
                   loop ()
                 end
               in
               loop ()
             with exn ->
               let cause =
                 Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn
               in
               causes := cause :: !causes;
               (try switch_fail frame sw Stop with _ -> ()))
       done
     with Stop -> ());
    match List.rev !causes with
    | [] -> ok (Array.to_list results |> List.map Option.get)
    | causes -> error (Cause.concurrent causes)

let for_each_par_bounded ~max xs f =
  if max <= 0 then invalid_arg "Effect.for_each_par_bounded: max must be > 0";
  let n = List.length xs in
  let xs_arr = Array.of_list xs in
  let tasks = Array.map f xs_arr in
  make @@ fun () ->
    let frame = current_frame () in
    let results = Array.make n None in
    let causes = ref [] in
    let next = P_atomic.make 0 in
    let exception Stop in
    let workers = min max n in
    let run_task effect =
      exit_to_value frame
        (try effect.eval () with exn -> exit_of_exn frame exn)
    in
    (try
       switch_run frame @@ fun sw ->
       for _ = 1 to workers do
         fiber_fork frame ~sw (fun () ->
             frame.runtime.tracer#with_fiber_context @@ fun () ->
             with_frame frame @@ fun () ->
             try
               let rec loop () =
                 let i = P_atomic.fetch_and_add next 1 in
                 if i < n then begin
                   results.(i) <- Some (run_task (Array.unsafe_get tasks i));
                   loop ()
                 end
               in
               loop ()
             with exn ->
               let cause =
                 Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn
               in
               causes := cause :: !causes;
               (try switch_fail frame sw Stop with _ -> ()))
       done
     with Stop -> ());
    match List.rev !causes with
    | [] -> ok (Array.to_list results |> List.map Option.get)
    | causes -> error (Cause.concurrent causes)

let uninterruptible effect =
  preserve effect @@ fun () -> Runtime_core.cancel_protect (fun () -> effect.eval ())

let repeat schedule effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let run_iteration () =
    let finalizers = ref [] in
    let iteration_frame = { frame with finalizers } in
    Runtime_core.with_finalizers ~runtime:frame.runtime ~fail_key:frame.fail_key
      finalizers (fun () -> run_to_value iteration_frame effect)
  in
  try
    run_iteration ();
    let driver = ref (Sch.start ~random:frame.runtime.random schedule) in
    let continue = ref true in
    while !continue do
      match Sch.next !driver with
      | None -> continue := false
      | Some (duration, next_driver) ->
          driver := next_driver;
          frame.runtime.sleep duration;
          run_iteration ()
    done;
    ok ()
  with exn -> exit_of_exn frame exn

let retry schedule predicate effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let driver = ref (Sch.start ~random:frame.runtime.random schedule) in
  let rec loop () =
    match effect.eval () with
    | Exit.Ok _ as ok -> ok
    | Exit.Error (Cause.Fail err) when predicate err -> (
        match Sch.next !driver with
        | Some (duration, next_driver) ->
            driver := next_driver;
            frame.runtime.sleep duration;
            loop ()
        | None -> error (Cause.Fail err))
    | Exit.Error _ as err -> err
  in
  loop ()

let acquire_release ~acquire ~release =
  preserve acquire @@ fun () ->
  let frame = current_frame () in
  match acquire.eval () with
  | Exit.Error _ as err -> err
  | Exit.Ok value ->
      frame.finalizers :=
        (fun () ->
          let release_finalizers = ref [] in
          let release_frame = { frame with finalizers = release_finalizers } in
          Runtime_core.with_finalizers ~runtime:frame.runtime ~fail_key:frame.fail_key
            release_finalizers (fun () -> run_to_value release_frame (release value)))
        :: !(frame.finalizers);
      ok value

let with_resource ~acquire ~release body =
  acquire_release ~acquire ~release |> bind body

let scoped effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  try
    ok
      (let run_scoped sw =
         let finalizers = ref [] in
         let child_frame = { frame with sw; finalizers } in
         Runtime_core.with_finalizers ~runtime:frame.runtime ~fail_key:frame.fail_key
           finalizers (fun () -> run_to_value child_frame effect)
       in
       if Runtime_core.has_eio_fiber_context () then switch_run frame run_scoped
       else run_scoped frame.sw)
  with exn -> exit_of_exn frame exn

let rec interpret_supervisor_scope :
    type s err a. frame -> (s, a, err) supervisor_scope -> a =
 fun frame scope ->
  match scope with
  | Supervisor_pure value -> value
  | Supervisor_lift effect -> run_to_value frame effect
  | Supervisor_fail err -> Runtime_core.raise_fail frame.fail_key err
  | Supervisor_bind (scope, k) ->
      let value = interpret_supervisor_scope frame scope in
      interpret_supervisor_scope frame (k value)
  | Supervisor_start (supervisor, child_scope) ->
      let promise, resolver = Eio.Promise.create () in
      let resolved = Atomic.make false in
      let cancel_requested = Atomic.make false in
      let resolve value =
        if Atomic.compare_and_set resolved false true then
          Eio.Promise.resolve resolver value
      in
      let child_sw = ref None in
      let child_cancel = ref None in
      Runtime_supervisor.fork supervisor (fun () ->
          frame.runtime.tracer#with_fiber_context @@ fun () ->
          let result =
            try
              cancel_sub frame @@ fun cancel_context ->
              child_cancel := Some cancel_context;
              if Atomic.get cancel_requested then cancel_cancel frame cancel_context Exit;
              switch_run frame @@ fun sw ->
              child_sw := Some sw;
              let finalizers = ref [] in
              let child_frame =
                { frame with sw; finalizers; error_renderer = default_renderer }
              in
              Ok
                (Runtime_core.with_finalizers ~runtime:frame.runtime
                   ~fail_key:frame.fail_key finalizers (fun () ->
                     interpret_supervisor_scope child_frame child_scope))
            with exn -> Error (Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn)
          in
          (match result with
          | Ok _ -> ()
          | Error cause -> Runtime_supervisor.record_failure supervisor cause);
          resolve result);
      let cancel () =
        if not (Atomic.get resolved) then (
          Atomic.set cancel_requested true;
          match !child_cancel with
          | None -> ()
          | Some cancel_context ->
              cancel_cancel frame cancel_context Exit;
              (match !child_sw with
              | None -> ()
              | Some child_switch ->
                  (try switch_fail frame child_switch Exit with _ -> ())))
      in
      Runtime_supervisor.register_child supervisor cancel;
      Runtime_supervisor.make_child ~promise ~cancel
  | Supervisor_await child -> (
      match Eio.Promise.await (Runtime_supervisor.child_promise child) with
      | Ok value -> value
      | Error cause -> Runtime_core.raise_cause frame.fail_key cause)
  | Supervisor_cancel child -> (
      Runtime_supervisor.child_cancel child ();
      match Eio.Promise.await (Runtime_supervisor.child_promise child) with
      | Ok _ -> ()
      | Error cause when Cause.is_interrupt_only cause -> ()
      | Error cause -> Runtime_core.raise_cause frame.fail_key cause)
  | Supervisor_failures supervisor -> List.rev (Runtime_supervisor.failures supervisor)
  | Supervisor_check supervisor -> (
      match Runtime_supervisor.max_failures supervisor with
      | None -> ()
      | Some max ->
          let count = Runtime_supervisor.failure_count supervisor in
          if count >= max then Runtime_core.raise_fail frame.fail_key (`Supervisor_failed count))
  | Supervisor_yield -> fiber_yield frame

let supervisor_scoped ?max_failures body =
  make @@ fun () ->
  let frame = current_frame () in
  try
    ok
      (switch_run frame @@ fun sw ->
       let supervisor = Runtime_supervisor.make ~sw ~max_failures in
       let finalizers = ref [] in
       let child_frame = { frame with sw; finalizers } in
       Runtime_core.with_finalizers ~runtime:frame.runtime ~fail_key:frame.fail_key
         finalizers (fun () ->
           Fun.protect
             ~finally:(fun () -> Runtime_supervisor.cancel_children supervisor)
             (fun () -> interpret_supervisor_scope child_frame (body.run supervisor))))
  with exn -> exit_of_exn frame exn

let with_error_renderer render effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let frame = { frame with error_renderer = (fun err -> render (Obj.obj err)) } in
  run_to_exit frame effect

let suppress_observability effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let runtime =
    {
      frame.runtime with
      tracing_enabled = false;
      auto_instrument = false;
      logging_enabled = false;
      metrics_enabled = false;
    }
  in
  run_to_exit { frame with runtime } effect

let named_kind ?error_renderer ~kind name effect =
  make ~leaf_name:name ~names:(name :: effect.names) @@ fun () ->
  let frame = current_frame () in
  let frame =
    match error_renderer with
    | None -> frame
    | Some render -> { frame with error_renderer = (fun err -> render (Obj.obj err)) }
  in
  try
    ok
      (Runtime_instrument.with_span ~runtime:frame.runtime
         ~error_renderer:frame.error_renderer ~fail_key:frame.fail_key ~kind
         ~name ~attrs:[] (fun () -> run_to_value frame effect))
  with exn -> exit_of_exn frame exn

let named ?error_renderer name effect =
  named_kind ?error_renderer ~kind:Capabilities.Internal name effect

let with_background ?name background use =
  let background = match name with None -> background | Some name -> named name background in
  supervisor_scoped
    {
      run =
        (fun supervisor ->
          Supervisor_bind
            ( Supervisor_start (supervisor, Supervisor_lift background),
              fun _ -> Supervisor_lift (use ()) ));
    }

let annotate ~key ~value effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  (if frame.runtime.tracing_enabled then
    match Eio.Fiber.get RObs.active_span_key with
    | Some span_id -> frame.runtime.tracer#add_attr_to ~span_id ~key ~value
    | None -> frame.runtime.tracer#add_attr ~key ~value);
  RObs.with_die_annotation key value @@ fun () -> effect.eval ()

let link_span ?(attrs = []) ~trace_id ~span_id effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let link =
    { Capabilities.link_trace_id = trace_id; link_span_id = span_id; link_attrs = attrs }
  in
  (if frame.runtime.tracing_enabled then
    match Eio.Fiber.get RObs.active_span_key with
    | Some span_id -> frame.runtime.tracer#add_link_to ~span_id link
    | None -> frame.runtime.tracer#add_link link);
  effect.eval ()

let with_context ctx effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  Eio.Fiber.with_binding RObs.trace_context_key ctx @@ fun () ->
  if frame.runtime.tracing_enabled then
    Eio.Fiber.with_binding RObs.sampled_key (Trace_context.sampled ctx) effect.eval
  else effect.eval ()

let with_external_parent ~trace_id ~span_id effect =
  match Trace_context.make ~trace_id ~span_id () with
  | Some ctx -> with_context ctx effect
  | None -> invalid_arg "Effect.with_external_parent: invalid trace context"

let current_span =
  make @@ fun () ->
  let frame = current_frame () in
  if not frame.runtime.tracing_enabled then ok None
  else
    match Eio.Fiber.get RObs.active_span_key with
    | None -> ok None
    | Some span_id -> ok (frame.runtime.tracer#inspect ~span_id)

let current_context =
  make @@ fun () ->
  let frame = current_frame () in
  if not frame.runtime.tracing_enabled then ok (Eio.Fiber.get RObs.trace_context_key)
  else
    match Eio.Fiber.get RObs.active_span_key with
    | Some span_id -> (
        match frame.runtime.tracer#inspect ~span_id with
        | Some info ->
            ok
              (Some
                 {
                   Capabilities.trace_id = info.trace_id;
                   span_id = info.span_id;
                   trace_flags = info.trace_flags;
                   trace_state = info.trace_state;
                   baggage = info.baggage;
                 })
        | None -> ok (Eio.Fiber.get RObs.trace_context_key))
    | None -> ok (Eio.Fiber.get RObs.trace_context_key)

let log ?(level = Capabilities.Info) ?(attrs = []) body =
  make @@ fun () ->
  let frame = current_frame () in
  (if frame.runtime.logging_enabled then
    let trace_id, span_id =
      if not frame.runtime.tracing_enabled then ("", "")
      else
        match Eio.Fiber.get RObs.active_span_key with
        | None -> ("", "")
        | Some span_id -> (
            match frame.runtime.tracer#inspect ~span_id with
            | None -> ("", "")
            | Some info -> (info.trace_id, info.span_id))
    in
    frame.runtime.logger#log
      { Capabilities.level; body; ts_ms = frame.runtime.now_ms (); attrs; trace_id; span_id });
  ok ()

let metric_update ?(description = "") ?(unit_ = "") ?(attrs = []) ~name ~kind value =
  make @@ fun () ->
  let frame = current_frame () in
  (if frame.runtime.metrics_enabled then
    frame.runtime.meter#record ~name ~description ~unit_ ~kind ~attrs ~value
      ~ts_ms:(frame.runtime.now_ms ()));
  ok ()

let metric_updates updates =
  make @@ fun () ->
  let frame = current_frame () in
  (if frame.runtime.metrics_enabled then
    let ts_ms = frame.runtime.now_ms () in
    List.iter
      (fun (name, description, unit_, kind, attrs, value) ->
        frame.runtime.meter#record ~name ~description ~unit_ ~kind ~attrs ~value ~ts_ms)
      updates);
  ok ()

let metric_updates_lazy make_updates =
  make @@ fun () ->
  let frame = current_frame () in
  if frame.runtime.metrics_enabled then (metric_updates (make_updates ())).eval () else ok ()

let island ?(name = "island") f input =
  make ~names:[ name ] @@ fun () ->
  let frame = current_frame () in
  try ok (Island_runtime.submit name (Runtime_core.island_pool frame.runtime None) f input)
  with exn -> exit_of_exn frame exn

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
    make ~names:[ name ] @@ fun () ->
    let frame = current_frame () in
    try ok (Island_runtime.submit_map name (Runtime_core.island_pool frame.runtime pool) f inputs)
    with exn -> exit_of_exn frame exn

  let map_result ?(name = "island.map_result") ?pool ~f inputs =
    make ~names:[ name ] @@ fun () ->
    let frame = current_frame () in
    try ok (Island_runtime.submit_map_result name (Runtime_core.island_pool frame.runtime pool) f inputs)
    with exn -> exit_of_exn frame exn

  let all_settled ?(name = "island.all_settled") ?pool ~f inputs =
    make ~names:[ name ] @@ fun () ->
    let frame = current_frame () in
    let _ = name in
    try ok (Island_runtime.submit_all_settled (Runtime_core.island_pool frame.runtime pool) f inputs)
    with exn -> exit_of_exn frame exn
end

module Blocking = struct
  type ('a, 'err) effect = ('a, 'err) t

  module Pool = struct
    include Blocking_runtime.Pool

    let shutdown pool =
      make @@ fun () ->
      let frame = current_frame () in
      try
        Blocking_runtime.shutdown ~emit:Runtime_observability.emit_current_blocking_event pool;
        ok ()
      with exn -> exit_of_exn frame exn
  end

  let submit ?pool ?(name = "blocking") ?on_cancel f =
    Blocking_runtime.check_not_worker "Effect.Blocking.submit";
    make ~names:[ name ] @@ fun () ->
    let frame = current_frame () in
    let run () =
      Blocking_runtime.submit ~sw:frame.runtime.outer_sw
        ~emit:(Runtime_core.emit_blocking_event frame.runtime)
        (Runtime_core.blocking_pool frame.runtime pool) name ?on_cancel f
    in
    try
      ok
        (if frame.runtime.auto_instrument then
           Runtime_instrument.instrument_leaf ~runtime:frame.runtime
             ~error_renderer:frame.error_renderer ~fail_key:frame.fail_key ~name run
         else run ())
    with exn -> exit_of_exn frame exn
end

let blocking ?pool ?(name = "blocking") ?on_cancel f =
  Blocking.submit ?pool ~name ?on_cancel f

let supervisor_pure value = Supervisor_pure value
let supervisor_lift effect = Supervisor_lift effect
let supervisor_fail err = Supervisor_fail err
let supervisor_bind k effect = Supervisor_bind (effect, k)
let supervisor_start supervisor effect = Supervisor_start (supervisor, effect)
let supervisor_await child = Supervisor_await child
let supervisor_cancel child = Supervisor_cancel child
let supervisor_failures supervisor = Supervisor_failures supervisor
let supervisor_check supervisor = Supervisor_check supervisor
let supervisor_yield = Supervisor_yield

let here_attr (file, line, col_start, col_end) effect =
  annotate ~key:"loc"
    ~value:(Printf.sprintf "%s:%d:%d-%d" file line col_start col_end)
    effect

let fn ?(kind = Capabilities.Internal) ?error_renderer pos name effect =
  effect |> here_attr pos |> named_kind ?error_renderer ~kind name

let name effect = effect.leaf_name
let collect_names effect = effect.names

let daemon_internal effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  P_atomic.incr frame.runtime.active;
  fiber_fork_daemon frame ~sw:frame.runtime.outer_sw (fun () ->
      frame.runtime.tracer#with_fiber_context @@ fun () ->
      Fun.protect
        ~finally:(fun () -> P_atomic.decr frame.runtime.active)
        (fun () ->
          (try
             switch_run frame @@ fun sw ->
             let finalizers = ref [] in
             let child_frame =
               { frame with sw; finalizers; error_renderer = default_renderer }
             in
             Runtime_core.with_finalizers ~runtime:frame.runtime
               ~fail_key:frame.runtime.default_fail_key finalizers (fun () ->
                 run_to_value child_frame effect)
           with exn ->
             Runtime_core.cause_of_exn_runtime frame.runtime
               frame.runtime.default_fail_key exn
             |> Runtime_core.emit_daemon_failure frame.runtime);
          `Stop_daemon));
  ok ()

let run runtime effect =
  if Blocking_runtime.in_worker () then
    invalid_arg
      "Eta.Runtime.run must not be called from inside an Effect.Blocking worker callback";
  runtime.Runtime_core.tracer#with_fiber_context @@ fun () ->
  let finalizers = ref [] in
  let frame =
    {
      runtime = (Obj.magic runtime : Obj.t Runtime_core.t);
      error_renderer = default_renderer;
      fail_key = runtime.Runtime_core.default_fail_key;
      sw = runtime.Runtime_core.outer_sw;
      finalizers;
    }
  in
  try
    let body () =
      Runtime_core.with_finalizers ~runtime ~fail_key:runtime.default_fail_key
        finalizers (fun () -> run_to_value frame effect)
    in
    ok
      (if runtime.Runtime_core.tracing_enabled
       || runtime.Runtime_core.metrics_enabled
      then
        RObs.with_blocking_event_emit
          (Runtime_core.emit_blocking_event runtime)
          body
      else body ())
  with exn ->
    error (Runtime_core.cause_of_exn_runtime runtime runtime.default_fail_key exn)

module Private = struct
  let daemon = daemon_internal
  let named_attrs ~kind name ~attrs effect =
    List.fold_right (fun (key, value) acc -> annotate ~key ~value acc) attrs
      (named_kind ~kind name effect)
  let metric_updates = metric_updates
  let metric_updates_lazy = metric_updates_lazy

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
