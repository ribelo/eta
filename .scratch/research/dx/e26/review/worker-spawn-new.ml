open Eta

let with_worker worker use =
  let open Syntax in
  let* name = Effect.fresh_named "worker" in
  Effect.with_background ~name (worker ~name) (fun () -> use ~name)
