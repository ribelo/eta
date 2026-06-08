(* MUST FAIL when temporarily added to dune.

   Property: GADT presence-set app_layer still demands Clock at boot. *)

open Layer_research

let _ =
  let log = Services.make_log () in
  let env =
    Gadt_presence_set.Env.cons Gadt_presence_set.Env.Log log
      Gadt_presence_set.Env.empty
  in
  Gadt_presence_set.Layer.use env Gadt_presence_set.app_layer
    Gadt_presence_set.app_program
