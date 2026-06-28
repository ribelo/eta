(* Predicted error:
   Library_evolution.Env_row.V2.top gained a metrics capability at the leaf.
   Booting with only clock must fail at the run boundary with a missing
   metrics method. *)

open R_followup_research

let _ =
  let env =
    object
      method clock = Services.clock 42
    end
  in
  Services.run_with_env env (Library_evolution.Env_row.V2.top ())
