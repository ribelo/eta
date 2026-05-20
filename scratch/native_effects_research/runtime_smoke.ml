let expect_ok label expected = function
  | Ok actual when actual = expected -> ()
  | Ok actual ->
      failwith
        (Printf.sprintf "%s: expected %S, got %S" label expected actual)
  | Error _ -> failwith (label ^ ": unexpected typed failure")

let expect_unhandled label f =
  match f () with
  | exception Effect.Unhandled _ -> ()
  | exception exn ->
      failwith
        (Printf.sprintf "%s: expected Effect.Unhandled, got %s" label
           (Printexc.to_string exn))
  | Ok _ -> failwith (label ^ ": expected Effect.Unhandled, got Ok")
  | Error _ -> failwith (label ^ ": expected Effect.Unhandled, got Error")

let () =
  expect_ok "raw boot" "[main] 42" (Native_effects_research.R_d_raw.boot ());
  expect_unhandled "raw no handler"
    Native_effects_research.R_d_raw.unsafe_boot_no_handler;
  expect_ok "presence-set boot" "[main] 42"
    (Native_effects_research.R_d_typed.Presence_set.boot ());
  expect_ok "scoped-token boot" "[main] 42"
    (Native_effects_research.R_d_typed.Scoped_token.boot ());
  print_endline "native_effects_research runtime smoke passed"
