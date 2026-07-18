(* Fire-and-forget cleanup — old ignore (pre-E2) *)

let best_effort cleanup =
  cleanup |> Effect.ignore

(* Discards success value AND suppresses typed failures.
   Reads like Stdlib.ignore; defects still surface.
   One name for two policies. *)
