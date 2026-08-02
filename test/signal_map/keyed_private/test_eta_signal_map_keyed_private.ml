module E = Eta.Effect
module S = Eta_signal_map_api.Make (Eta_signal.No_observer_error) ()

module Order = struct
  type t = int

  let compare = Int.compare
end

module M = Eta_signal_map_api.Map.Make (Order)
module K = S.Keyed (Order)
module T = K.Testing

type test_error = [ S.graph_error | S.observer_read_error | S.stabilize_error ]

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let run_ok runtime eff =
  Eta_test.Expect.expect_ok (Eta.Runtime.run runtime (widen eff))

let run_exit runtime eff = Eta.Runtime.run runtime (widen eff)

let expect_defect label = function
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Error _ -> Alcotest.failf "%s: expected defect" label
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected failure" label

let test_keyed_mapi_commit_removes_before_additions () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let input = S.Var.create (M.set 1 10 M.empty) in
  let output = K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data -> data) in
  let events = ref [] in
  T.set_event_recorder output (fun event -> events := !events @ [ event ]);
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  events := [];
  let removed =
    match T.entry_identity output 1 with
    | Some identity -> identity
    | None -> Alcotest.fail "missing committed entry"
  in
  run_ok runtime (S.Var.set input (M.set 2 20 M.empty));
  run_ok runtime S.stabilize;
  (match !events with
   | [ T.Detached detached; T.Invalidated invalidated; T.Attached _ ] ->
       Alcotest.(check bool) "detached exact scope" true
         (detached == removed.keyed_scope_token);
       Alcotest.(check bool) "invalidated exact scope" true
         (invalidated == removed.keyed_scope_token)
   | events ->
       let labels =
         List.map
           (function
             | T.Detached _ -> "detached"
             | T.Invalidated _ -> "invalidated"
             | T.Attached _ -> "attached")
           events
       in
       Alcotest.failf "unexpected structural event order: %s"
         (String.concat "," labels));
  Alcotest.(check bool) "old scope invalid" false
    (T.scope_valid removed.keyed_scope_token);
  run_ok runtime (S.Observer.dispose observer)

let test_keyed_mapi_preflight_failure_preserves_committed_snapshot () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let input = S.Var.create (M.set 1 10 M.empty) in
  let provisional_data = ref None in
  let output =
    K.mapi (S.Var.watch input) ~f:(fun ~key ~data ->
        if key = 2 then provisional_data := Some data;
        data)
  in
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  let before =
    match T.entry_identity output 1 with
    | Some identity -> identity
    | None -> Alcotest.fail "missing committed entry"
  in
  T.set_preflight output (fun () -> failwith "preflight");
  run_ok runtime (S.Var.set input (M.set 2 20 M.empty));
  expect_defect "preflight" (run_exit runtime S.stabilize);
  Alcotest.(check bool) "no pending plan" false (T.pending output);
  let after =
    match T.entry_identity output 1 with
    | Some identity -> identity
    | None -> Alcotest.fail "committed entry disappeared"
  in
  Alcotest.(check bool) "scope preserved" true
    (before.keyed_scope_token == after.keyed_scope_token);
  Alcotest.(check bool) "scope remains valid" true
    (T.scope_valid before.keyed_scope_token);
  Alcotest.(check (list (pair int int))) "output preserved" [ (1, 10) ]
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  T.set_preflight output (fun () -> ());
  run_ok runtime S.stabilize;
  Alcotest.(check (list (pair int int))) "retry commits" [ (2, 20) ]
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  (match !provisional_data with
   | None -> Alcotest.fail "builder did not run"
   | Some _ -> ());
  run_ok runtime (S.Observer.dispose observer)

let () =
  Alcotest.run "eta_signal_map_keyed_private"
    [
      ( "keyed",
        [
          Alcotest.test_case "keyed_mapi_commit_removes_before_additions" `Quick
            test_keyed_mapi_commit_removes_before_additions;
          Alcotest.test_case
            "keyed_mapi_preflight_failure_preserves_committed_snapshot" `Quick
            test_keyed_mapi_preflight_failure_preserves_committed_snapshot;
        ] );
    ]
