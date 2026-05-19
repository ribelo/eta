(* Property: distinct abstract newtype modules cannot be mixed.
   Expected compiler error: Email.t is not assignable to User_id.t. *)

let bad () =
  match B_b_abstract_newtype.Email.decode (B_b_abstract_newtype.Json.String "a@b") with
  | Ok email -> B_b_abstract_newtype.use_user_id email
  | Error _ -> ()

