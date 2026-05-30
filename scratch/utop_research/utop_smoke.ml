Eta_utop.run (Eta.Effect.pure 42);;
Eta_utop.run_exn (Eta.Effect.map (( + ) 1) (Eta.Effect.pure 42));;
Eta_utop.run (Eta.Effect.blocking (fun () -> 7));;
