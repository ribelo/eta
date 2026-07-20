(* Same module as module-handwritten.ml with [@@eta.trace]. *)
open Eta

type err = [ `Not_found of string | `Db of int ]

let lookup_user id =
  Effect.sync_result (fun () ->
      if id <= 0 then Error (`Not_found "user") else Ok ("user:" ^ string_of_int id))
[@@eta.trace]

let save_user ~name =
  Effect.sync_result (fun () ->
      if String.equal name "" then Error (`Db 22) else Ok ())
[@@eta.trace]

let greet ~name = Effect.pure ("hello " ^ name) [@@eta.trace]
