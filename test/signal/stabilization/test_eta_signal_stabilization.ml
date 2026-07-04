module S = Eta_signal_stabilization

let expect_invalid_arg label f =
  match f () with
  | exception Invalid_argument _ -> ()
  | exception exn ->
      Alcotest.failf "%s: expected Invalid_argument, got %s" label
        (Printexc.to_string exn)
  | _ -> Alcotest.failf "%s: expected Invalid_argument" label

let test_begin_commit_finish () =
  let state = S.create () in
  Alcotest.(check bool) "starts idle" true
    (match S.state state with
    | Idle -> true
    | Pure | Delivering -> false);
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected idle begin to succeed"
  in
  Alcotest.(check bool) "pure" true (S.is_pure state);
  ignore (S.commit_to_delivering state pure : S.delivering S.token);
  Alcotest.(check bool) "delivering" true
    (match S.state state with
    | Delivering -> true
    | Idle | Pure -> false);
  S.finish state;
  Alcotest.(check bool) "finished idle" true
    (match S.state state with
    | Idle -> true
    | Pure | Delivering -> false)

let test_reentrant_begin_rejected () =
  let state = S.create () in
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected first begin to succeed"
  in
  (match S.begin_pure state with
   | Error `Reentrant_stabilization -> ()
   | Ok _ -> Alcotest.fail "expected reentrant pure begin to fail");
  ignore (S.commit_to_delivering state pure : S.delivering S.token);
  (match S.begin_pure state with
   | Error `Reentrant_stabilization -> ()
   | Ok _ -> Alcotest.fail "expected delivering begin to fail")

let test_rollback_invalidates_pure_token () =
  let state = S.create () in
  let pure =
    match S.begin_pure state with
    | Ok pure -> pure
    | Error `Reentrant_stabilization ->
        Alcotest.fail "expected begin to succeed"
  in
  ignore (S.rollback_to_idle state pure : S.idle S.token);
  Alcotest.(check bool) "rolled back idle" true
    (match S.state state with
    | Idle -> true
    | Pure | Delivering -> false);
  expect_invalid_arg "reused pure token" (fun () ->
      ignore (S.commit_to_delivering state pure : S.delivering S.token))

let () =
  Alcotest.run "eta_signal_stabilization"
    [
      ( "stabilization",
        [
          Alcotest.test_case "begin commit finish" `Quick
            test_begin_commit_finish;
          Alcotest.test_case "reentrant begin rejected" `Quick
            test_reentrant_begin_rejected;
          Alcotest.test_case "rollback invalidates pure token" `Quick
            test_rollback_invalidates_pure_token;
        ] );
    ]
