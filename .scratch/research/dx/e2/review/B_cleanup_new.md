(* Fire-and-forget cleanup — honest split (E2) *)

(* Value unused; failures must still fail the workflow *)
let notice_failures cleanup =
  cleanup |> Effect.discard

(* Best-effort: typed failures ok to drop; defects still surface *)
let best_effort cleanup =
  cleanup |> Effect.ignore_errors
