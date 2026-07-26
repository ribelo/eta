open Eta

(* RED-TEAM PROBE 2 — the nesting-direction mismatch.

   Same three fetches, right-nested this time ([par a (par b c)]), but the
   pattern keeps the left-nested shape from probe 1's corrected version.
   The two spellings look interchangeable at a glance and are not.
   Expected: type error. *)

let program fetch_config fetch_profile fetch_billing =
  Effect.par fetch_config (Effect.par fetch_profile fetch_billing)
  |> Effect.map (fun ((x, y), z) -> x + y + z)
