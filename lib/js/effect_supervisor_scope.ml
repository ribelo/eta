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

and ('s, 'err) supervisor = ('s, 'err) Runtime_supervisor.supervisor
and ('s, 'err, 'a) supervisor_child = ('s, 'err, 'a) Runtime_supervisor.child

let interrupt_cause : Obj.t Cause.t = Cause.interrupt

let await_runtime_promise promise on_result =
  async_leaf (fun context ~resume ~on_cancel ->
      let active = ref true in
      on_cancel (fun () -> active := false);
      Runtime_promise.await promise ~scheduler:context.scheduler
        (fun result ->
          if !active then begin
            active := false;
            resume (on_result result)
          end))

let await_child child =
  await_runtime_promise
    (Runtime_supervisor.child_promise child)
    (function
      | Ok value -> Exit.ok value
      | Error cause -> Exit.error cause)

let cancel_child_effect child =
  async_leaf (fun context ~resume ~on_cancel ->
      let active = ref true in
      on_cancel (fun () -> active := false);
      Runtime_supervisor.child_cancel child ();
      Runtime_promise.await
        (Runtime_supervisor.child_promise child)
        ~scheduler:context.scheduler
        (fun result ->
          if !active then begin
            active := false;
            match result with
            | Ok _ -> resume (Exit.ok ())
            | Error cause when Cause.is_interrupt_only cause ->
                resume (Exit.ok ())
            | Error cause -> resume (Exit.error cause)
          end))

let await_settled promise =
  await_runtime_promise promise (fun () -> Exit.ok ())

let rec await_registrations = function
  | [] -> pure ()
  | registration :: rest ->
      bind
        (fun () -> await_registrations rest)
        (await_settled (Runtime_supervisor.registration_settled registration))

let cancel_children_and_wait supervisor =
  sync (fun () ->
      Runtime_supervisor.live_children supervisor
      |> List.iter Runtime_supervisor.cancel_registration)
  |> bind (fun () ->
         Runtime_supervisor.live_children supervisor
         |> List.rev |> await_registrations)

let rec to_effect : type s a err. (s, a, err) supervisor_scope -> (a, err) t =
  function
  | Supervisor_pure value -> pure value
  | Supervisor_lift eff -> eff
  | Supervisor_fail err -> fail err
  | Supervisor_bind (scope, k) -> bind (fun value -> to_effect (k value)) (to_effect scope)
  | Supervisor_start (supervisor, child_scope) ->
      async_leaf (fun context ~resume ~on_cancel:_ ->
          let promise, resolver = Runtime_promise.create () in
          let settled, settled_resolver = Runtime_promise.create () in
          let child_fiber = ref None in
          let cancel_requested = ref false in
          let cancel () =
            if not !cancel_requested then begin
              cancel_requested := true;
              match !child_fiber with
              | None -> ()
              | Some fiber -> Runtime_fiber.cancel fiber interrupt_cause
            end
          in
          let child_id =
            Runtime_supervisor.register_child supervisor ~cancel ~settled
          in
          let child = Runtime_supervisor.make_child ~promise ~cancel in
          let fiber = Runtime_fiber.create_child context.fiber in
          child_fiber := Some fiber;
          let child_context = { context with fiber } in
          ignore
            (Js.Promise.then_
               (fun exit ->
                 Runtime_fiber.finish fiber (Runtime_fiber.Exit exit);
                 Runtime_supervisor.unregister_child supervisor child_id;
                 let result =
                   match exit with
                   | Exit.Ok value -> Ok value
                   | Exit.Error cause -> Error cause
                 in
                 (match result with
                 | Ok _ -> ()
                 | Error cause ->
                     Runtime_supervisor.record_failure supervisor cause);
                 Runtime_promise.resolve resolver result;
                 Runtime_promise.resolve settled_resolver ();
                 Js.Promise.resolve ())
               (run_promise child_context (to_effect child_scope)));
          resume (Exit.ok child))
  | Supervisor_await child -> await_child child
  | Supervisor_cancel child -> cancel_child_effect child
  | Supervisor_failures supervisor -> pure (List.rev (Runtime_supervisor.failures supervisor))
  | Supervisor_check supervisor -> (
      match Runtime_supervisor.max_failures supervisor with
      | None -> pure ()
      | Some max ->
          let count = Runtime_supervisor.failure_count supervisor in
          if count >= max then fail (`Supervisor_failed count) else pure ())
  | Supervisor_yield -> yield_now

let supervisor_scoped ?max_failures body =
  bind
    (fun supervisor ->
      finally
        (cancel_children_and_wait supervisor)
        (to_effect (body.run supervisor)))
    (sync (fun () -> Runtime_supervisor.make ~max_failures))

let with_background ?name background use =
  (match name with
  | None -> ()
  | Some _ ->
      invalid_arg
        "Eta_js.Effect.with_background: ?name requires observability support");
  supervisor_scoped
    {
      run =
        (fun supervisor ->
          Supervisor_bind
            ( Supervisor_start (supervisor, Supervisor_lift background),
              fun child ->
                Supervisor_lift
                  (finally (cancel_child_effect child) (use ())) ));
    }

let supervisor_pure value = Supervisor_pure value
let supervisor_lift eff = Supervisor_lift eff
let supervisor_fail err = Supervisor_fail err
let supervisor_bind k scope = Supervisor_bind (scope, k)
let supervisor_start supervisor scope = Supervisor_start (supervisor, scope)
let supervisor_await child = Supervisor_await child
let supervisor_cancel child = Supervisor_cancel child
let supervisor_failures supervisor = Supervisor_failures supervisor
let supervisor_check supervisor = Supervisor_check supervisor
let supervisor_yield = Supervisor_yield
