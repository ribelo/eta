(* Predicted: compile error.

   Property: the presence-set candidate can reject running a program when
   the handler list does not contain every requested capability. The failure
   is at run/boot, not at construction. *)

open Native_effects_research.R_d_typed.Presence_set

let _ =
  let db = Native_effects_research.Services.Db.make "main" in
  run (HDb (db, HNil)) (a db_witness log_witness "42")
