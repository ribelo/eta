type ('a, 'err) waiter = {
  mutable active : bool;
  callback : ('a, 'err) Exit.t -> unit;
}

type ('a, 'err) t = {
  mutable completed : ('a, 'err) Exit.t option;
  mutable waiters : ('a, 'err) waiter list;
}

let make () =
  Effect_core.async_leaf (fun _context ~resume ~on_cancel ->
      resume (Exit.ok { completed = None; waiters = [] });
      on_cancel (fun () -> ()))

let make_unsafe () = { completed = None; waiters = [] }

let poll t =
  match t.completed with
  | Some exit ->
      Some
        (match exit with
        | Exit.Ok value -> Ok value
        | Exit.Error cause -> Error cause)
  | None -> None

let await t =
  match t.completed with
  | Some (Exit.Ok value) -> Effect_core.pure value
  | Some (Exit.Error cause) -> Effect_core.fail (Obj.magic cause)
  | None ->
      Effect_core.async_leaf (fun _context ~resume ~on_cancel ->
          match t.completed with
          | Some (Exit.Ok value) -> resume (Exit.ok value)
          | Some (Exit.Error cause) -> resume (Exit.error (Obj.magic cause))
          | None ->
              let waiter =
                {
                  active = true;
                  callback =
                    (fun exit ->
                      match exit with
                      | Exit.Ok value -> resume (Exit.ok value)
                      | Exit.Error cause -> resume (Exit.error (Obj.magic cause)));
                }
              in
              t.waiters <- waiter :: t.waiters;
              on_cancel (fun () -> waiter.active <- false))

let done_ t exit =
  Effect_core.sync (fun () ->
      match t.completed with
      | Some _ -> false
      | None ->
          t.completed <- Some exit;
          List.iter
            (fun waiter -> if waiter.active then waiter.callback exit)
            (List.rev t.waiters);
          true)

let succeed t value = done_ t (Exit.ok value)
let fail t err = done_ t (Exit.error (Cause.fail err))
let fail_cause t cause = done_ t (Exit.error cause)
let interrupt t = done_ t (Exit.error Cause.interrupt)
