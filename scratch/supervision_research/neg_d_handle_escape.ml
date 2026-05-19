(* Negative test: a child handle from F-D must not escape Supervisor.scoped.

   Predicted error: the record field [run] is less general because its return
   type mentions the locally bound phantom scope ['s]. This defends the
   structured-concurrency invariant that users cannot await/cancel children
   after the supervisor scope has closed. *)

open F_d_supervisor_scope

let escaped =
  let open Effect in
  supervise {
    run =
      fun (type s) sup ->
        let** (child : (s, [> `Boom ], int) child) = start sup (s_pure 1) in
        s_pure child;
  }
