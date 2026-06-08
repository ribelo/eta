(* Property: two private string abbreviations remain nominally distinct.
   Expected compiler error: Email.t is not assignable to User_id.t. *)

let bad () =
  match B_d_private_abbrev.Email.decode (B_d_private_abbrev.Json.String "a@b") with
  | Ok email -> B_d_private_abbrev.use_user_id email
  | Error _ -> ()

