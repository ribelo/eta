(* DB lookup leaf — two-combinator recommended shape (pre-E1) *)

let load_user db id =
  Effect.sync (fun () -> Db.find db id)
  |> Effect.flatten_result

(* Ok user  -> success
   Error e  -> typed failure
   raise    -> Cause.Die
   Easy to forget the second combinator and leave nested result. *)
