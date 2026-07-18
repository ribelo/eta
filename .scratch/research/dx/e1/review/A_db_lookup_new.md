(* DB lookup leaf — named recommended shape (E1) *)

let load_user db id =
  Effect.sync_result (fun () -> Db.find db id)

(* Same semantics as sync |> flatten_result:
   Ok user  -> success
   Error e  -> typed failure
   raise    -> Cause.Die (not typed) *)
