(* Ugliest call site — lib/stream/eta_stream.ml Tap_error (new names). *)
(* Excerpt only; not standalone. *)
fold_stream inner acc folder
|> Eta.Effect.bind_error (fun error ->
       observe error
       |> Eta.Effect.bind (fun () -> Eta.Effect.fail error))
