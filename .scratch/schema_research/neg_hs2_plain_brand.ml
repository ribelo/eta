(* Property: H-S2 branded values cannot be forged from plain strings.
   Predicted: string is not assignable to User_id.t. *)

let bad : H_s2_decode_validate.User_id.t = "u_123"
