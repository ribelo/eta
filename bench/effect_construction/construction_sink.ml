let sink : (int, unit) Eta.Effect.t option ref = ref None

let[@inline never] consume eff =
  sink := Some eff

let[@inline never] fingerprint () =
  match !sink with
  | None -> failwith "construction benchmark did not retain a blueprint"
  | Some eff -> String.length (Eta.Effect.describe eff)
