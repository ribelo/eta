(* The same escape attempt written in the explicit (type s) style that
   test code uses. *)
open Eta

type error = [ `Boom ]

let program =
  Supervisor.scoped {
    run =
      fun (type s) (sup : (s, error) Supervisor.t) ->
        let open Supervisor.Scope in
        let* child = start sup (lift (Effect.pure 42)) in
        pure child;
  }
