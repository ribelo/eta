type ('a, 'err) t = {
  fiber : Runtime_fiber.t;
  mutable result : ('a, 'err Cause.t) result option;
}

let id handle = Runtime_fiber.id handle.fiber

let poll handle = handle.result

let await handle =
  match handle.result with
  | Some result -> Effect_core.pure result
  | None ->
      Effect_core.async_leaf (fun _context ~resume ~on_cancel ->
          Runtime_fiber.observe handle.fiber (function
            | Runtime_fiber.Exit exit ->
                let result =
                  match exit with
                  | Ok value -> Ok (Obj.magic value)
                  | Error cause -> Error (Obj.magic cause)
                in
                handle.result <- Some result;
                resume (Exit.ok result));
          on_cancel (fun () ->
              Runtime_fiber.cancel handle.fiber Cause.interrupt))

let join handle =
  Effect_core.bind
    (function
      | Ok value -> Effect_core.pure (Obj.magic value)
      | Error cause -> Effect_core.fail (Obj.magic cause))
    (await handle)

let interrupt handle =
  Effect_core.async_leaf (fun _context ~resume ~on_cancel ->
      Runtime_fiber.cancel handle.fiber Cause.interrupt;
      Runtime_fiber.observe handle.fiber (fun _ -> resume (Exit.ok ()));
      on_cancel (fun () -> ()))

let fork' ~detached eff =
  Effect_core.async_leaf (fun context ~resume ~on_cancel ->
      let runtime_fiber =
        if detached then
          Runtime_fiber.create_root
            ~scheduler:context.Effect_core.scheduler
        else Runtime_fiber.create_child context.Effect_core.fiber
      in
      let handle = { fiber = runtime_fiber; result = None } in
      Runtime_fiber.observe runtime_fiber (function
        | Runtime_fiber.Exit exit ->
            handle.result <- Some
              (match exit with
               | Ok value -> Ok (Obj.magic value)
               | Error cause -> Error (Obj.magic cause)));
      let child_context =
        { context with Effect_core.fiber = runtime_fiber }
      in
      ignore
        (Js.Promise.then_
           (fun exit ->
             Runtime_fiber.finish runtime_fiber
               (Runtime_fiber.Exit exit);
             Js.Promise.resolve ())
           (Effect_core.run_promise child_context eff));
      resume (Exit.ok handle);
      on_cancel (fun () ->
          Runtime_fiber.cancel runtime_fiber Cause.interrupt))

let fork eff = fork' ~detached:false eff
let fork_scoped eff = fork' ~detached:false eff
let fork_daemon eff =
  Effect_core.map (fun (_handle : (unit, 'err) t) -> ()) (fork' ~detached:true eff)
