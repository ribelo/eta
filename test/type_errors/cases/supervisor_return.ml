(* What a user writes when they want the child handle outside the nursery. *)
open Eta

let program =
  Supervisor.scoped {
    run =
      fun sup ->
        let open Supervisor.Scope in
        let* child = start sup (lift (Effect.pure 42)) in
        pure child;
  }
