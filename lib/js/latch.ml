type waiter = {
  mutable active : bool;
  resume : unit -> unit;
}

type t = {
  mutable released : bool;
  mutable waiters : waiter list;
}

let make () =
  Effect_core.async_leaf (fun _context ~resume ~on_cancel ->
      resume (Exit.ok { released = false; waiters = [] });
      on_cancel (fun () -> ()))

let make_unsafe () = { released = false; waiters = [] }
let is_released t = t.released

let await t =
  if t.released then Effect_core.pure ()
  else
    Effect_core.async_leaf (fun _context ~resume ~on_cancel ->
        let waiter = { active = true; resume = (fun () -> resume (Exit.ok ())) } in
        t.waiters <- waiter :: t.waiters;
        on_cancel (fun () -> waiter.active <- false))

let release t =
  Effect_core.sync (fun () ->
      if t.released then false
      else begin
        t.released <- true;
        List.iter
          (fun waiter -> if waiter.active then waiter.resume ())
          (List.rev t.waiters);
        t.waiters <- [];
        true
      end)
