(* Property: the functor helper must not expose a constructor or make function.
   Expected compiler error: User_id.make is unbound. *)

let bad = B_c_witness_newtype.User_id.make "usr_1"
