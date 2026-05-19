(* Property: private string abbreviations cannot be forged from raw strings.
   Expected compiler error: string is not assignable to User_id.t. *)

let bad : B_d_private_abbrev.User_id.t = "usr_1"

