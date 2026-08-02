module E = Eta.Effect
module S = Eta_signal_kernel.Make_no_error ()

type test_error = [ S.graph_error | S.observer_read_error | S.stabilize_error ]

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let run_ok runtime eff =
  Eta_test.Expect.expect_ok (Eta.Runtime.run runtime (widen eff))

let test_affected_child_notification_avoids_scan () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let left_source = S.Var.create 1 in
  let right_source = S.Var.create 10 in
  let left_child = S.Var.watch left_source |> S.map (fun value -> value + 1) in
  let right_child =
    S.Var.watch right_source |> S.map (fun value -> value + 1)
  in
  let left_notifications = ref 0 in
  let right_notifications = ref 0 in
  let left_listener () = incr left_notifications in
  let right_listener () = incr right_notifications in
  S.Extension.add_dirty_listener left_child left_listener;
  S.Extension.add_dirty_listener right_child right_listener;
  let combined = S.map2 ( + ) left_child right_child in
  let observer =
    run_ok runtime (S.Observer.observe combined (fun _ -> E.unit))
  in
  run_ok runtime S.stabilize;
  left_notifications := 0;
  right_notifications := 0;
  run_ok runtime (S.Var.set left_source 2);
  run_ok runtime S.stabilize;
  Alcotest.(check int) "affected child notified once" 1 !left_notifications;
  Alcotest.(check int) "unaffected child not visited" 0 !right_notifications;
  S.Extension.remove_dirty_listener left_child left_listener;
  S.Extension.remove_dirty_listener right_child right_listener;
  run_ok runtime (S.Observer.dispose observer)

let test_preflight_orders_owner_before_descendant () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let source = S.Var.create 1 in
  let descendant = ref None in
  let owner =
    S.bind (S.Var.watch source) (fun value ->
        let child = S.const value |> S.map Fun.id in
        descendant := Some child;
        child)
  in
  let observer = run_ok runtime (S.Observer.observe owner (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  let descendant =
    match !descendant with
    | Some descendant -> descendant
    | None -> Alcotest.fail "missing descendant"
  in
  let order = ref [] in
  let owner_plan =
    S.Extension.preflight_plan owner (fun () -> order := !order @ [ "owner" ])
  in
  let descendant_plan =
    S.Extension.preflight_plan descendant (fun () ->
        order := !order @ [ "descendant" ])
  in
  S.Extension.preflight_owner_before_descendant
    [ descendant_plan; owner_plan ];
  Alcotest.(check (list string)) "preflight order"
    [ "owner"; "descendant" ] !order;
  run_ok runtime (S.Observer.dispose observer)

let () =
  Alcotest.run "eta_signal_kernel"
    [
      ( "extension",
        [
          Alcotest.test_case "affected child notification avoids scan" `Quick
            test_affected_child_notification_avoids_scan;
          Alcotest.test_case "preflight orders owner before descendant" `Quick
            test_preflight_orders_owner_before_descendant;
        ] );
    ]
