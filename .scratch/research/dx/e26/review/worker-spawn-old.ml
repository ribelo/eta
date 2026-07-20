open Eta

(* Application code must own synchronization, reset, and counter lifetime. *)
let next_worker = Atomic.make 0

let next_worker_name () =
  Effect.sync (fun () ->
      let id = Atomic.fetch_and_add next_worker 1 + 1 in
      Printf.sprintf "worker-%d" id)

let with_worker worker use =
  let open Syntax in
  let* name = next_worker_name () in
  Effect.with_background ~name (worker ~name) (fun () -> use ~name)
