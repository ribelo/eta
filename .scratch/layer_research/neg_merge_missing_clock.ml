(* MUST FAIL when temporarily added to dune.

   Property: merge_explicit's app layer still demands Clock at boot. *)

open Layer_research

let _ =
  let log = Services.make_log () in
  let env = object method log = log end in
  Services.run_with_env env
    (Merge_explicit.Layer.use (Merge_explicit.app_layer ()) Merge_explicit.app_program)
