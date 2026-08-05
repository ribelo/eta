module E = Eta.Effect
module Signal = Eta_signal.Make (Eta_signal.No_observer_error) ()
module Signal_map = Eta_signal_map.Make (Signal.Package)
module S = Signal

module Order = struct
  type t = int

  let compare = Int.compare
end

module M = Eta_signal_map.Map.Make (Order)
module K = Signal_map.Keyed (Order)

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

let test_keyed_mapi_adds_child () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let input = S.Var.create M.empty in
  let output =
    K.mapi (S.Var.watch input) ~f:(fun ~key ~data ->
        S.map (fun value -> key + value) data)
  in
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set input (M.set 2 10 M.empty));
  run_ok runtime S.stabilize;
  let actual = run_ok runtime (S.Observer.read observer) |> M.to_list in
  Alcotest.(check (list (pair int int))) "one child output" [ (2, 12) ] actual;
  run_ok runtime (S.Observer.dispose observer)

let test_keyed_mapi_retains_updates_and_removes_child () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let first = ref 10 in
  let second = ref 20 in
  let input = S.Var.create (M.set 1 first M.empty) in
  let builds = ref 0 in
  let output =
    K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data ->
        incr builds;
        S.map (fun value -> !value) data)
  in
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set input (M.set 1 second M.empty));
  run_ok runtime S.stabilize;
  Alcotest.(check int) "builder retained" 1 !builds;
  Alcotest.(check (list (pair int int))) "updated child" [ (1, 20) ]
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  run_ok runtime (S.Var.set input M.empty);
  run_ok runtime S.stabilize;
  Alcotest.(check (list (pair int int))) "removed child" []
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  run_ok runtime (S.Observer.dispose observer)

let test_keyed_mapi_child_only_change_patches_output () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let locals = Hashtbl.create 2 in
  let input = S.Var.create (M.set 1 10 (M.set 2 20 M.empty)) in
  let output =
    K.mapi (S.Var.watch input) ~f:(fun ~key ~data ->
        let local = S.Var.create 0 in
        Hashtbl.add locals key local;
        S.map2 ( + ) data (S.Var.watch local))
  in
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set (Hashtbl.find locals 1) 5);
  run_ok runtime S.stabilize;
  Alcotest.(check (list (pair int int))) "one child patched"
    [ (1, 15); (2, 20) ]
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  run_ok runtime (S.Observer.dispose observer)

let test_keyed_mapi_builder_defect_rolls_back_and_retries () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let input = S.Var.create M.empty in
  let fail = ref true in
  let builds = ref 0 in
  let output =
    K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data ->
        incr builds;
        if !fail then failwith "builder";
        data)
  in
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set input (M.set 1 10 M.empty));
  expect_defect "builder defect" (run_exit runtime S.stabilize);
  Alcotest.(check (list (pair int int))) "old output survives" []
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  fail := false;
  run_ok runtime S.stabilize;
  Alcotest.(check int) "builder retried" 2 !builds;
  Alcotest.(check (list (pair int int))) "retry output" [ (1, 10) ]
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  run_ok runtime (S.Observer.dispose observer)

let test_keyed_mapi_cutoff_defect_rolls_back_and_retries () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let old_data = ref 10 in
  let new_data = ref 20 in
  let input = S.Var.create (M.set 1 old_data M.empty) in
  let fail = ref true in
  let calls = ref 0 in
  let output =
    K.mapi
      ~data_cutoff:(fun ~published:_ ~candidate:_ ->
        incr calls;
        if !fail then failwith "cutoff";
        false)
      (S.Var.watch input) ~f:(fun ~key:_ ~data -> S.map ( ! ) data)
  in
  let observer = run_ok runtime (S.Observer.observe output (fun _ -> E.unit)) in
  run_ok runtime S.stabilize;
  run_ok runtime (S.Var.set input (M.set 1 new_data M.empty));
  expect_defect "cutoff defect" (run_exit runtime S.stabilize);
  Alcotest.(check (list (pair int int))) "old cutoff output" [ (1, 10) ]
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  fail := false;
  run_ok runtime S.stabilize;
  Alcotest.(check int) "cutoff retried" 2 !calls;
  Alcotest.(check (list (pair int int))) "new cutoff output" [ (1, 20) ]
    (run_ok runtime (S.Observer.read observer) |> M.to_list);
  run_ok runtime (S.Observer.dispose observer)

let () =
  Alcotest.run "eta_signal_map_keyed"
    [
      ( "keyed",
        [
          Alcotest.test_case "keyed_mapi_adds_child" `Quick
            test_keyed_mapi_adds_child;
          Alcotest.test_case "keyed_mapi_retains_updates_and_removes_child"
            `Quick test_keyed_mapi_retains_updates_and_removes_child;
          Alcotest.test_case "keyed_mapi_child_only_change_patches_output" `Quick
            test_keyed_mapi_child_only_change_patches_output;
          Alcotest.test_case
            "keyed_mapi_builder_defect_rolls_back_and_retries" `Quick
            test_keyed_mapi_builder_defect_rolls_back_and_retries;
          Alcotest.test_case "keyed_mapi_cutoff_defect_rolls_back_and_retries"
            `Quick test_keyed_mapi_cutoff_defect_rolls_back_and_retries;
        ] );
    ]
