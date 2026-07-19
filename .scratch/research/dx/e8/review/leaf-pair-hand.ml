open Eta

type error = [ `Missing_user of string ]

let load_user id =
  Effect.fn __POS__ __FUNCTION__
    (Effect.named "user.lookup"
       (Effect.sync_result (fun () ->
            if String.equal id "" then Error (`Missing_user id)
            else Ok { id; name = "user:" ^ id })))
