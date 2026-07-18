(* Red-team R2: smuggle the child out inside a tuple ("bundle it with the
   other result"). *)
open Eta

let program =
  Supervisor.scoped {
    run =
      fun sup ->
        let open Supervisor.Scope in
        let* child = start sup (lift (Effect.pure 42)) in
        pure (1, child);
  }
