type ('a, +'err) t = ('a, 'err) Effect_core.t

let pure = Effect_core.pure
let fail = Effect_core.fail
let unit = pure ()

let from_result = function
  | Ok value -> pure value
  | Error err -> fail err

let sync = Effect_core.sync
let yield_now = Effect_core.yield_now
let check = Effect_core.check
let map = Effect_core.map
let bind = Effect_core.bind
let tap f eff = bind (fun value -> map (fun () -> value) (f value)) eff
let seq first second = bind (fun () -> second) first
let concat effects = List.fold_right seq effects unit

let interrupt_cause : Obj.t Cause.t = Cause.interrupt

let run_child context eff on_exit =
  let child = Runtime_fiber.create_child context.Effect_core.fiber in
  let child_context = { context with fiber = child } in
  ignore
    (Js.Promise.then_
       (fun exit ->
         Runtime_fiber.finish child (Runtime_fiber.Exit exit);
         on_exit child exit;
         Js.Promise.resolve ())
       (Effect_core.run_promise child_context eff));
  child

let run_detached context eff on_exit =
  let fiber = Runtime_fiber.create_root ~scheduler:context.Effect_core.scheduler in
  let child_context = { context with fiber } in
  ignore
    (Js.Promise.then_
       (fun exit ->
         Runtime_fiber.finish fiber (Runtime_fiber.Exit exit);
         on_exit fiber exit;
         Js.Promise.resolve ())
       (Effect_core.run_promise child_context eff));
  fiber

let cancel_children children =
  List.iter (fun child -> Runtime_fiber.cancel child interrupt_cause) children

let combined_cause = function
  | [] -> invalid_arg "Eta_js.Effect: empty cause list"
  | [ cause ] -> cause
  | causes -> Cause.concurrent causes

let race effects =
  match effects with
  | [] -> invalid_arg "Eta_js.Effect.race: empty list"
  | _ ->
      Effect_core.async_leaf (fun context ~resume ~on_cancel ->
          let settled = ref false in
          let remaining = ref (List.length effects) in
          let failures = ref [] in
          let children = ref [] in
          let cancel_others winner =
            !children
            |> List.iter (fun child ->
                   if child != winner then Runtime_fiber.cancel child interrupt_cause)
          in
          on_cancel (fun () -> cancel_children !children);
          effects
          |> List.iter (fun eff ->
                 let child =
                   run_child context eff (fun child -> function
                     | Exit.Ok _ as exit ->
                         if not !settled then begin
                           settled := true;
                           cancel_others child;
                           resume exit
                         end
                     | Exit.Error cause ->
                         if not !settled then begin
                           decr remaining;
                           failures := cause :: !failures;
                           if !remaining = 0 then begin
                             settled := true;
                             resume
                               (Exit.error
                                  (combined_cause (List.rev !failures)))
                           end
                         end)
                 in
                 children := child :: !children))

let all effects =
  match effects with
  | [] -> pure []
  | _ ->
      Effect_core.async_leaf (fun context ~resume ~on_cancel ->
          let count = List.length effects in
          let remaining = ref count in
          let settled = ref false in
          let children = ref [] in
          let results = Array.make count None in
          on_cancel (fun () -> cancel_children !children);
          effects
          |> List.iteri (fun index eff ->
                 let child =
                   run_child context eff (fun _child -> function
                     | Exit.Ok value ->
                         if not !settled then begin
                           results.(index) <- Some value;
                           decr remaining;
                           if !remaining = 0 then begin
                             settled := true;
                             let values =
                               results |> Array.to_list
                               |> List.map (function
                                    | Some value -> value
                                    | None -> assert false)
                             in
                             resume (Exit.ok values)
                           end
                         end
                     | Exit.Error cause ->
                         if not !settled then begin
                           settled := true;
                           cancel_children !children;
                           resume (Exit.error cause)
                         end)
                 in
                 children := child :: !children))

let par left right =
  Effect_core.async_leaf (fun context ~resume ~on_cancel ->
      let settled = ref false in
      let left_result = ref None in
      let right_result = ref None in
      let children = ref [] in
      let maybe_finish () =
        match (!left_result, !right_result) with
        | Some left, Some right when not !settled ->
            settled := true;
            resume (Exit.ok (left, right))
        | _ -> ()
      in
      let handle_error cause =
        if not !settled then begin
          settled := true;
          cancel_children !children;
          resume (Exit.error cause)
        end
      in
      on_cancel (fun () -> cancel_children !children);
      let left_child =
        run_child context left (fun _child -> function
          | Exit.Ok value ->
              left_result := Some value;
              maybe_finish ()
          | Exit.Error cause -> handle_error cause)
      in
      children := left_child :: !children;
      let right_child =
        run_child context right (fun _child -> function
          | Exit.Ok value ->
              right_result := Some value;
              maybe_finish ()
          | Exit.Error cause -> handle_error cause)
      in
      children := right_child :: !children)

let all_settled effects =
  match effects with
  | [] -> pure []
  | _ ->
      Effect_core.async_leaf (fun context ~resume ~on_cancel ->
          let count = List.length effects in
          let remaining = ref count in
          let children = ref [] in
          let results = Array.make count None in
          on_cancel (fun () -> cancel_children !children);
          effects
          |> List.iteri (fun index eff ->
                 let child =
                   run_child context eff (fun _child exit ->
                       results.(index) <-
                         Some
                           (match exit with
                           | Exit.Ok value -> Ok value
                           | Exit.Error cause -> Error cause);
                       decr remaining;
                       if !remaining = 0 then
                         resume
                           (Exit.ok
                              (results |> Array.to_list
                              |> List.map (function
                                   | Some value -> value
                                   | None -> assert false))))
                 in
                 children := child :: !children))

let for_each_par xs f = all (List.map f xs)

let for_each_par_bounded ~max xs f =
  if max <= 0 then
    invalid_arg "Eta_js.Effect.for_each_par_bounded: max must be > 0";
  match xs with
  | [] -> pure []
  | _ ->
      Effect_core.async_leaf (fun context ~resume ~on_cancel ->
          let items = Array.of_list xs in
          let count = Array.length items in
          let next = ref 0 in
          let running = ref 0 in
          let remaining = ref count in
          let settled = ref false in
          let children = ref [] in
          let results = Array.make count None in
          let finish_error cause =
            if not !settled then begin
              settled := true;
              cancel_children !children;
              resume (Exit.error cause)
            end
          in
          let rec launch () =
            while (not !settled) && !running < max && !next < count do
              let index = !next in
              incr next;
              incr running;
              let eff =
                try f items.(index)
                with exn -> Effect_core.sync (fun () -> raise exn)
              in
              let child =
                run_child context eff (fun _child -> function
                  | Exit.Ok value ->
                      if not !settled then begin
                        decr running;
                        decr remaining;
                        results.(index) <- Some value;
                        if !remaining = 0 then begin
                          settled := true;
                          resume
                            (Exit.ok
                               (results |> Array.to_list
                               |> List.map (function
                                    | Some value -> value
                                    | None -> assert false)))
                        end
                        else launch ()
                      end
                  | Exit.Error cause ->
                      decr running;
                      finish_error cause)
              in
              children := child :: !children
            done
          in
          on_cancel (fun () -> cancel_children !children);
          launch ())

let sleep duration =
  if Duration.is_zero duration then yield_now
  else Effect_core.async_leaf (fun context ~resume ~on_cancel ->
      let cancel =
        context.clock.sleep duration (fun () -> resume (Exit.ok ()))
      in
      on_cancel cancel)

let delay duration eff = seq (sleep duration) eff

let timeout_as duration ~on_timeout eff =
  Effect_core.async_leaf (fun context ~resume ~on_cancel ->
      let settled = ref false in
      let timeout_fired = ref false in
      let body_child = ref None in
      let timer_child = ref None in
      let cancel_child = function
        | None -> ()
        | Some child -> Runtime_fiber.cancel child interrupt_cause
      in
      let finish exit =
        if not !settled then begin
          settled := true;
          resume exit
        end
      in
      let finish_timeout body_exit =
        match body_exit with
        | Exit.Ok _ as ok -> finish ok
        | Exit.Error cause when not (Cause.is_interrupt_only cause) ->
            finish (Exit.error (Cause.concurrent [ Cause.fail on_timeout; cause ]))
        | Exit.Error _ -> finish (Exit.error (Cause.fail on_timeout))
      in
      on_cancel (fun () ->
          cancel_child !body_child;
          cancel_child !timer_child);
      let body =
        run_child context eff (fun _child exit ->
            if not !settled then
              if !timeout_fired then finish_timeout exit
              else begin
                cancel_child !timer_child;
                finish exit
              end)
      in
      body_child := Some body;
      let timer =
        run_child context (delay duration unit) (fun _child -> function
          | Exit.Ok () ->
              if not !settled then begin
                timeout_fired := true;
                cancel_child !body_child
              end
          | Exit.Error _ -> ())
      in
      timer_child := Some timer)

let timeout duration eff = timeout_as duration ~on_timeout:`Timeout eff

let catch = Effect_core.catch
let map_error = Effect_core.map_error
let tap_error f eff =
  catch
    (fun err ->
      seq (sync (fun () -> f err)) (fail err))
    eff
let finally = Effect_core.finally
let uninterruptible = Effect_core.uninterruptible

let named _name eff = eff
let annotate _key _value eff = eff
let annotate_all _attrs eff = eff
let suppress_observability eff = eff

let log_level level msg =
  Effect_core.async_leaf (fun context ~resume ~on_cancel ->
      (match context.logger with
      | Some logger ->
          logger#log
            {
              Capabilities.level;
              body = msg;
              ts_ms = context.clock.now_ms ();
              attrs = [];
              trace_id = "";
              span_id = "";
            }
      | None -> ());
      resume (Exit.ok ());
      on_cancel (fun () -> ()))

let log msg = log_level Capabilities.Info msg
let log_debug msg = log_level Capabilities.Debug msg
let log_info msg = log_level Capabilities.Info msg
let log_warning msg = log_level Capabilities.Warn msg
let log_error msg = log_level Capabilities.Error msg

let retry schedule predicate eff =
  let rec loop driver =
    catch
      (fun err ->
        if predicate err then
          match Schedule.next driver with
          | None -> fail err
          | Some (duration, next_driver) -> delay duration (loop next_driver)
        else fail err)
      eff
  in
  loop (Schedule.start schedule)

let repeat schedule eff =
  let rec loop driver =
    bind
      (fun () ->
        match Schedule.next driver with
        | None -> unit
        | Some (duration, next_driver) -> delay duration (loop next_driver))
      eff
  in
  loop (Schedule.start schedule)

let fork = Fiber.fork
let fork_scoped = Fiber.fork_scoped
let fork_daemon = Fiber.fork_daemon

let die exn = Effect_core.sync (fun () -> raise exn)

let fail_cause cause =
  Effect_core.async_leaf (fun _context ~resume ~on_cancel ->
      resume (Exit.error (Obj.magic cause));
      on_cancel (fun () -> ()))

let sandbox eff =
  Effect_core.async_leaf (fun context ~resume ~on_cancel ->
      let child = Runtime_fiber.create_child context.Effect_core.fiber in
      let child_context = { context with fiber = child } in
      let settled = ref false in
      let finish result =
        if not !settled then begin
          settled := true;
          resume (Exit.ok result)
        end
      in
      ignore
        (Js.Promise.then_
           (fun exit ->
             Runtime_fiber.finish child (Runtime_fiber.Exit exit);
             (match exit with
             | Exit.Ok value -> finish (Ok (Obj.magic value))
             | Exit.Error cause -> finish (Error (Obj.magic cause)));
             Js.Promise.resolve ())
           (Effect_core.run_promise child_context eff));
      on_cancel (fun () -> Runtime_fiber.cancel child Cause.interrupt))

let unsandbox eff =
  Effect_core.async_leaf (fun context ~resume ~on_cancel ->
      ignore
        (Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok (Ok value) -> resume (Exit.ok (Obj.magic value))
             | Exit.Ok (Error cause) -> resume (Exit.error (Obj.magic cause))
             | Exit.Error cause -> resume (Exit.error (Obj.magic cause)));
             Js.Promise.resolve ())
           (Effect_core.run_promise context eff));
      on_cancel (fun () -> ()))

let catch_cause handler eff =
  Effect_core.async_leaf (fun context ~resume ~on_cancel ->
      let child = Runtime_fiber.create_child context.Effect_core.fiber in
      let child_context = { context with fiber = child } in
      let settled = ref false in
      let run_handler cause =
        if not !settled then begin
          settled := true;
          ignore
            (Js.Promise.then_
               (fun handler_exit ->
                 if not !settled then resume handler_exit;
                 Js.Promise.resolve ())
               (Effect_core.run_promise context (handler cause)))
        end
      in
      ignore
        (Js.Promise.then_
           (fun exit ->
             Runtime_fiber.finish child (Runtime_fiber.Exit exit);
             (match exit with
             | Exit.Ok value ->
                 if not !settled then begin
                   settled := true;
                   resume (Exit.ok (Obj.magic value))
                 end
             | Exit.Error cause -> run_handler cause);
             Js.Promise.resolve ())
           (Effect_core.run_promise child_context eff));
      on_cancel (fun () -> Runtime_fiber.cancel child Cause.interrupt))

let tap_cause f eff =
  catch_cause
    (fun cause ->
      seq (sync (fun () -> f cause)) (fail_cause cause))
    eff

let match_ ~on_success ~on_failure eff =
  Effect_core.async_leaf (fun context ~resume ~on_cancel ->
      let child = Runtime_fiber.create_child context.Effect_core.fiber in
      let child_context = { context with fiber = child } in
      let settled = ref false in
      ignore
        (Js.Promise.then_
           (fun exit ->
             Runtime_fiber.finish child (Runtime_fiber.Exit exit);
             if not !settled then begin
               settled := true;
               (match exit with
               | Exit.Ok value -> resume (Exit.ok (on_success (Obj.magic value)))
               | Exit.Error cause ->
                   resume (Exit.ok (on_failure (Obj.magic cause))))
             end;
             Js.Promise.resolve ())
           (Effect_core.run_promise child_context eff));
      on_cancel (fun () -> Runtime_fiber.cancel child Cause.interrupt))

let match_effect ~on_success ~on_failure eff =
  Effect_core.async_leaf (fun context ~resume ~on_cancel ->
      let child = Runtime_fiber.create_child context.Effect_core.fiber in
      let child_context = { context with fiber = child } in
      let settled = ref false in
      let run_promise eff =
        Js.Promise.then_
          (fun handler_exit ->
            if not !settled then begin
              settled := true;
              resume handler_exit
            end;
            Js.Promise.resolve ())
          (Effect_core.run_promise context eff)
      in
      ignore
        (Js.Promise.then_
           (fun exit ->
             Runtime_fiber.finish child (Runtime_fiber.Exit exit);
             if not !settled then begin
               (match exit with
               | Exit.Ok value -> ignore (run_promise (on_success (Obj.magic value)))
               | Exit.Error cause ->
                   ignore (run_promise (on_failure (Obj.magic cause))))
             end;
             Js.Promise.resolve ())
           (Effect_core.run_promise child_context eff));
      on_cancel (fun () -> Runtime_fiber.cancel child Cause.interrupt))

let daemon eff =
  Effect_core.async_leaf (fun context ~resume ~on_cancel:_ ->
      context.daemon_started ();
      ignore
        (run_detached context eff (fun _fiber -> function
          | Exit.Ok () -> context.daemon_finished ()
          | Exit.Error cause ->
              context.daemon_failed (Obj.magic cause);
              context.daemon_finished ()));
      resume (Exit.ok ()))

let acquire_use_release ~acquire ~release body =
  bind (fun value -> finally (release value) (body value)) acquire

module Expert = struct
  type context = Effect_core.context

  let scheduler context = context.Effect_core.scheduler
  let async_leaf = Effect_core.async_leaf
end

include Effect_supervisor_scope
