open Eta

(* RED-TEAM PROBE 3 — the par3 spelling.

   The pattern the sugar intends: flat triple, flat pattern.
   Expected: compiles. *)

let program fetch_config fetch_profile fetch_billing =
  Effect.par3 fetch_config fetch_profile fetch_billing
  |> Effect.map (fun (x, y, z) -> x + y + z)
