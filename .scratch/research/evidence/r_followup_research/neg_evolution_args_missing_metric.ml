(* Predicted error:
   The explicit-args variant gained a metrics argument, so every pass-through
   call site that omits ~metrics fails directly at construction. *)

open R_followup_research

let _ =
  Library_evolution.Args.V2.top ~clock:(Services.clock 42)
