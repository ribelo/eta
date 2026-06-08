let expect_ok label expected effect =
  match Eta_utop.run effect with
  | Eta.Exit.Ok actual when actual = expected ->
      Printf.printf "OK %s\n" label
  | Eta.Exit.Ok _ -> failwith (label ^ ": unexpected success value")
  | Eta.Exit.Error cause ->
      failwith
        (Format.asprintf "%s: unexpected error %a" label
           (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<typed>"))
           cause)

let () =
  expect_ok "pure" 42 (Eta.Effect.pure 42);
  expect_ok "map" 43 (Eta.Effect.map (( + ) 1) (Eta.Effect.pure 42));
  expect_ok "blocking" 7 (Eta.Effect.blocking (fun () -> 7));
  Printf.printf "eta_utop smoke complete\n"
