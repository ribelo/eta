open Effet

let leaked =
  Supervisor.scoped
    { run =
        (fun (type s) sup ->
          let open Supervisor.Scope in
          let* child = start sup (lift (Effect.pure 1)) in
          pure child);
    }
