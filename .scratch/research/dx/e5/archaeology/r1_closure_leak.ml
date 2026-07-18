(* Red-team R1: smuggle the child out inside a closure ("I'll just defer
   the await"). *)
open Eta

let program =
  Supervisor.scoped {
    run =
      fun sup ->
        let open Supervisor.Scope in
        let* child = start sup (lift (Effect.pure 42)) in
        pure (fun () -> child);
  }
