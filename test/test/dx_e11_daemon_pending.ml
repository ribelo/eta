let () =
  let program : (unit, string) Eta.Effect.t =
    Eta.Effect.daemon Eta.Effect.never
  in
  let outcome = Eta_test.Run.run program in
  Format.printf "%a@."
    (Eta_test.Run.pp (fun fmt () -> Format.pp_print_string fmt "()")
       Format.pp_print_string)
    outcome;
  match outcome.pending_fibers with
  | [ { Eta_test.Run.kind = Daemon; _ } ] -> ()
  | _ -> failwith "expected one runtime-owned daemon in the pending snapshot"
