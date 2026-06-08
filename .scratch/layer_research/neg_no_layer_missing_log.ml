(* MUST FAIL when temporarily added to dune.

   Property: the no-Layer baseline makes missing boot arguments a direct
   function-application error. *)

open Layer_research

let _ =
  let clock = Services.make_clock () in
  No_layer_baseline.boot clock
