open Eta

type session_error = Boom

let child_escapes () =
  Supervisor.scoped
    {
      run =
        (fun (type s) sup ->
          let open Supervisor.Scope in
          let* (child : (s, session_error, unit) Supervisor.child) =
            start sup (lift Effect.unit)
          in
          pure child);
    }

let _ = child_escapes

