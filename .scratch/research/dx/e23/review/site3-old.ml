(* Ugliest call site — lib/stream/eta_stream.ml Tap_error (old names). *)
(* Excerpt only; not standalone. *)
fold_stream inner acc folder
|> Eta.Effect.catch (fun error ->
       observe error
       |> Eta.Effect.bind (fun () -> Eta.Effect.fail error))
