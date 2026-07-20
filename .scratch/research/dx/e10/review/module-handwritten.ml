(* Small realistic service module: three fn-wrapped definitions. *)
open Eta

type err = [ `Not_found of string | `Db of int ]

let lookup_user id =
  Effect.fn __POS__ __FUNCTION__
    (Effect.sync_result (fun () ->
         if id <= 0 then Error (`Not_found "user") else Ok ("user:" ^ string_of_int id)))

let save_user ~name =
  Effect.fn __POS__ __FUNCTION__
    (Effect.sync_result (fun () ->
         if String.equal name "" then Error (`Db 22) else Ok ()))

let greet ~name =
  Effect.fn __POS__ __FUNCTION__ (Effect.pure ("hello " ^ name))
