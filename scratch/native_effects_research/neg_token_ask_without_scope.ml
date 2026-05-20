(* Predicted: compile error.

   Property: the scoped-token candidate can make ask itself unavailable
   outside a handler scope. The price is that every function using a service
   must receive and thread the token explicitly. *)

open Native_effects_research.R_d_typed.Scoped_token

let _ = ask Db
