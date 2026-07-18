(* Archaeology A: return a child handle from the Supervisor.scoped body. *)
open Eta

let program =
  Supervisor.scoped {
    run =
      fun sup ->
        let open Supervisor.Scope in
        let* child = start sup (lift (Effect.pure 42)) in
        pure child;
  }
