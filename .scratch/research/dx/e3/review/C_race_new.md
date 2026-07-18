(* Timeout-vs-result heterogeneous race — race_either (E3) *)

let race_timeout_vs_work timeout_eff work_eff =
  Effect.race_either timeout_eff work_eff
(* `Left timeout | `Right value; first arg = Left, second = Right *)
