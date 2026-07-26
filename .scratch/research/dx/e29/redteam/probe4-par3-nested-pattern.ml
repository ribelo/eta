open Eta

(* RED-TEAM PROBE 4 — does par3 admit a NEW mismatch class?

   A user carrying the nested-pair habit writes the nested pattern against
   par3's flat triple. par3 must reject it exactly as strictly as the
   status quo rejects probe 1 — same static fence, no new hole.
   Expected: type error. *)

let program fetch_config fetch_profile fetch_billing =
  Effect.par3 fetch_config fetch_profile fetch_billing
  |> Effect.map (fun ((x, y), z) -> x + y + z)
