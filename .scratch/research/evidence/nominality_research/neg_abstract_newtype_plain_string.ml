(* Property: abstract newtype values cannot be forged from raw strings.
   Expected compiler error: string is not assignable to User_id.t. *)

let bad : B_b_abstract_newtype.User_id.t = "usr_1"
