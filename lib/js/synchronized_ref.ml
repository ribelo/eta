type 'a t = {
  mutable value : 'a;
  mutable locked : bool;
  mutable waiters : (unit -> unit) list;
}

let make v =
  Effect_core.async_leaf (fun _context ~resume ~on_cancel ->
      resume (Exit.ok { value = v; locked = false; waiters = [] });
      on_cancel (fun () -> ()))

let make_unsafe v = { value = v; locked = false; waiters = [] }

let get t = Effect_core.sync (fun () -> t.value)

let with_lock t f =
  Effect_core.async_leaf (fun context ~resume ~on_cancel ->
      let rec run () =
        if not t.locked then begin
          t.locked <- true;
          ignore
            (Js.Promise.then_
               (fun exit ->
                 t.locked <- false;
                 let waiters = t.waiters in
                 t.waiters <- [];
                 List.iter (fun w -> w ()) (List.rev waiters);
                 (match exit with
                 | Exit.Ok v -> resume (Exit.ok v)
                 | Exit.Error cause -> resume (Exit.error cause));
                 Js.Promise.resolve ())
               (Effect_core.run_promise context (f ())))
        end else
          t.waiters <- (fun () -> run ()) :: t.waiters
      in
      run ();
      on_cancel (fun () -> ()))

let update_effect t f =
  with_lock t (fun () ->
      Effect_core.bind
        (fun new_value ->
          Effect_core.sync (fun () -> t.value <- new_value))
        (f t.value))

let modify_effect t f =
  with_lock t (fun () ->
      Effect_core.bind
        (fun (result, new_value) ->
          Effect_core.sync (fun () ->
              t.value <- new_value;
              result))
        (f t.value))
