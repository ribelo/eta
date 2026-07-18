(* Timeout-vs-result heterogeneous race — map-wrapped (pre-E3) *)

let race_timeout_vs_work timeout_eff work_eff =
  Effect.race
    [
      timeout_eff |> Effect.map (fun t -> `Timeout t);
      work_eff |> Effect.map (fun v -> `Done v);
    ]

(* Uniform success type forced by hand; same cancel semantics as race. *)
