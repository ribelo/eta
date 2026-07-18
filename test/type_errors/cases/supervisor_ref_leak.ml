(* What a user writes when they try to smuggle the child out through a ref. *)
open Eta

let stolen = ref None

let program =
  Supervisor.scoped {
    run =
      fun sup ->
        let open Supervisor.Scope in
        let* child = start sup (lift (Effect.pure 42)) in
        stolen := Some child;
        pure ();
  }

let () = ignore stolen
