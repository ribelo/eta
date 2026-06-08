type 'a t = { mutable value : 'a }

let make v =
  Effect_core.async_leaf (fun _context ~resume ~on_cancel ->
      resume (Exit.ok { value = v });
      on_cancel (fun () -> ()))

let make_unsafe v = { value = v }

let get t = Effect_core.sync (fun () -> t.value)
let set t v = Effect_core.sync (fun () -> t.value <- v)
let update t f = Effect_core.sync (fun () -> t.value <- f t.value)

let get_and_set t v =
  Effect_core.sync (fun () ->
      let old = t.value in
      t.value <- v;
      old)

let update_and_get t f =
  Effect_core.sync (fun () ->
      t.value <- f t.value;
      t.value)

let modify t f =
  Effect_core.sync (fun () ->
      let result, new_value = f t.value in
      t.value <- new_value;
      result)
