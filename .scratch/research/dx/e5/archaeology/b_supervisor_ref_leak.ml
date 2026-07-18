(* Archaeology B: leak a child handle through a top-level ref. *)
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
