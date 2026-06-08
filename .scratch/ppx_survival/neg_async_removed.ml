(* Predicted: compile error.

   Property: after the single-leaf decision, [%effet.async] is not accepted.
   The public PPX surface has [%effet.fn], [%effet.thunk], and [%effet.env]. *)

let _ = [%effet.async "removed" ()]
