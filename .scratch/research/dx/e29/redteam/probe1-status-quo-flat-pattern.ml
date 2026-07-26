open Eta

(* RED-TEAM PROBE 1 — the status-quo footgun.

   Three concurrent fetches spelled the only way E9b allows:
   [par (par a b) c]. The user thinks in a flat triple and destructures
   with the flat triple pattern they meant. Expected: type error. *)

let program fetch_config fetch_profile fetch_billing =
  Effect.par (Effect.par fetch_config fetch_profile) fetch_billing
  |> Effect.map (fun (x, y, z) -> x + y + z)
