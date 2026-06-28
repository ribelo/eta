(* This is intentionally not negative: it compiles.
   Two independent libraries can both require env#query : string -> string
   with different semantics. Structural rows cannot distinguish them. *)

open R_followup_research

let _ = Naming_collision.run_generic_collision ()
