(** Supervisor scope GADT, interpreter, and constructor wrappers. Internal: see
    Effect for the public surface. *)

open Effect_core

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

let with_background ?name background use =
  let background =
    match name with
    | None -> background
    | Some name -> Effect_observability.named name background
  in
  supervisor_scoped
    {
      run =
        (fun supervisor ->
          Supervisor_bind
            ( Supervisor_start (supervisor, Supervisor_lift background),
              fun _ -> Supervisor_lift (use ()) ));
    }

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
