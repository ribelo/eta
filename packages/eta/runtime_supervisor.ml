let make ~sw ~max_failures =
  {
    Runtime_supervisor_types.sw;
    max_failures;
    failures = Atomic.make [];
    failure_count = Atomic.make 0;
    children = Atomic.make [];
  }

let fork supervisor body =
  Eio.Fiber.fork ~sw:supervisor.Runtime_supervisor_types.sw body

let max_failures supervisor = supervisor.Runtime_supervisor_types.max_failures

let record_failure supervisor failure =
  let rec push () =
    let failures = Atomic.get supervisor.Runtime_supervisor_types.failures in
    if
      not
        (Atomic.compare_and_set supervisor.failures failures
           (failure :: failures))
    then push ()
  in
  push ();
  Atomic.incr supervisor.failure_count

let failures supervisor = Atomic.get supervisor.Runtime_supervisor_types.failures
let failure_count supervisor = Atomic.get supervisor.Runtime_supervisor_types.failure_count

let register_child supervisor cancel =
  let rec push () =
    let children = Atomic.get supervisor.Runtime_supervisor_types.children in
    if
      not
        (Atomic.compare_and_set supervisor.children children (cancel :: children))
    then push ()
  in
  push ()

let cancel_children supervisor =
  List.iter
    (fun cancel -> cancel ())
    (Atomic.get supervisor.Runtime_supervisor_types.children)

let make_child ~promise ~cancel = { Runtime_supervisor_types.promise; cancel }
let child_promise child = child.Runtime_supervisor_types.promise
let child_cancel child = child.Runtime_supervisor_types.cancel

module type INTERPRETER = sig
  val interpret_ast :
    error_renderer:('err -> string) ->
    fail_key:Runtime_core.Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    ('a, 'err) Effect_ast.t ->
    'a
end

module Make (I : INTERPRETER) = struct
  let rec interpret_scope :
      type s err a.
      runtime:_ Runtime_core.t ->
      error_renderer:(err -> string) ->
      fail_key:Runtime_core.Typed_fail.key ->
      sw:Eio.Switch.t ->
      finalizers:(unit -> unit) list ref ->
      (s, a, err) Effect_ast.supervisor_scope ->
      a =
   fun ~runtime ~error_renderer ~fail_key ~sw ~finalizers eff ->
    match eff with
    | Effect_ast.Supervisor_pure value -> value
    | Effect_ast.Supervisor_lift child_effect ->
        I.interpret_ast ~error_renderer ~fail_key ~sw ~finalizers child_effect
    | Effect_ast.Supervisor_fail err -> Runtime_core.raise_fail fail_key err
    | Effect_ast.Supervisor_bind (scope_effect, k) ->
        let value =
          interpret_scope ~runtime ~error_renderer ~fail_key ~sw ~finalizers
            scope_effect
        in
        interpret_scope ~runtime ~error_renderer ~fail_key ~sw ~finalizers
          (k value)
    | Effect_ast.Supervisor_start (supervisor, child_effect) ->
        let promise, resolver = Eio.Promise.create () in
        let resolved = Atomic.make false in
        let cancel_requested = Atomic.make false in
        let resolve value =
          if Atomic.compare_and_set resolved false true then
            Eio.Promise.resolve resolver value
        in
        let child_sw = ref None in
        let child_cancel = ref None in
        fork supervisor (fun () ->
            runtime.tracer#with_fiber_context @@ fun () ->
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
                  (Runtime_core.with_finalizers ~runtime ~fail_key
                     child_finalizers (fun () ->
                       interpret_scope ~runtime
                         ~error_renderer:
                           Runtime_observability.default_error_renderer
                         ~fail_key ~sw:child_switch
                         ~finalizers:child_finalizers child_effect))
              with exn ->
                Error (Runtime_core.cause_of_exn_runtime runtime fail_key exn)
            in
            (match result with
            | Ok _ -> ()
            | Error cause -> record_failure supervisor cause);
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
        register_child supervisor cancel;
        make_child ~promise ~cancel
    | Effect_ast.Supervisor_await child -> (
        match Eio.Promise.await (child_promise child) with
        | Ok value -> value
        | Error cause -> Runtime_core.raise_cause fail_key cause)
    | Effect_ast.Supervisor_cancel child -> child_cancel child ()
    | Effect_ast.Supervisor_failures supervisor -> List.rev (failures supervisor)
    | Effect_ast.Supervisor_check supervisor -> (
        match max_failures supervisor with
        | None -> ()
        | Some max ->
            let count = failure_count supervisor in
            if count >= max then
              Runtime_core.raise_fail fail_key (`Supervisor_failed count))
    | Effect_ast.Supervisor_yield -> Eio.Fiber.yield ()
end
