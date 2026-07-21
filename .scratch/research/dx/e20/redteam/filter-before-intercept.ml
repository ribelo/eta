open Eta

let expected_to_observe_but_cannot =
  let observed = ref false in
  let observe record =
    observed := true;
    Some record
  in
  let effect =
    Effect.log_debug "below minimum"
    |> Effect.intercept_log observe
    |> Effect.with_minimum_log_level Capabilities.Warn
  in
  (effect, observed)

(* Running [effect] leaves [observed] false: the minimum-level filter owns the
   earlier pipeline stage, exactly as the [intercept_log] mli states. *)
