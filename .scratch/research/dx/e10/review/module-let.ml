(* Same module as module-handwritten.ml with let%eta. *)
open Eta

type err = [ `Not_found of string | `Db of int ]

let%eta lookup_user id =
  Effect.sync_result (fun () ->
      if id <= 0 then Error (`Not_found "user") else Ok ("user:" ^ string_of_int id))

let%eta save_user ~name =
  Effect.sync_result (fun () ->
      if String.equal name "" then Error (`Db 22) else Ok ())

let%eta greet ~name = Effect.pure ("hello " ^ name)
