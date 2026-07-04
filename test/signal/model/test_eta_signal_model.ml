module E = Eta.Effect

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp formatter = function
    | `Observer_failed -> Format.pp_print_string formatter "observer failed"
end

module Signal = Eta_signal.Make (Observer_error) ()

type test_error =
  [ Signal.graph_error
  | Signal.observer_read_error
  | Signal.stabilize_error ]

type observed_update =
  | Initialized of int
  | Changed of int * int

type op =
  | Set_a of int
  | Set_b of int
  | Choose_a of bool
  | Stabilize
  | Read

type model = {
  mutable pending_a : int;
  mutable pending_b : int;
  mutable pending_choose_a : bool;
  mutable committed_a : int;
  mutable committed_b : int;
  mutable committed_choose_a : bool;
  mutable observer_current : int option;
  mutable observed_updates : observed_update list;
}

let pp_hidden formatter _ = Format.pp_print_string formatter "<signal-error>"

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let run_ok runtime eff =
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Eta.Cause.pp pp_hidden) cause

let pp_observed_update formatter = function
  | Initialized value -> Format.fprintf formatter "Initialized %d" value
  | Changed (old_value, new_value) ->
      Format.fprintf formatter "Changed { old_value = %d; new_value = %d }"
        old_value new_value

let observed_update =
  Alcotest.testable pp_observed_update (fun left right -> left = right)

let pp_op formatter = function
  | Set_a value -> Format.fprintf formatter "Set_a %d" value
  | Set_b value -> Format.fprintf formatter "Set_b %d" value
  | Choose_a value -> Format.fprintf formatter "Choose_a %b" value
  | Stabilize -> Format.pp_print_string formatter "Stabilize"
  | Read -> Format.pp_print_string formatter "Read"

let model_value model =
  let selected =
    if model.committed_choose_a then model.committed_a else model.committed_b
  in
  ((model.committed_a + model.committed_b) * 10) + selected

let create_model () =
  {
    pending_a = 1;
    pending_b = 10;
    pending_choose_a = true;
    committed_a = 1;
    committed_b = 10;
    committed_choose_a = true;
    observer_current = None;
    observed_updates = [];
  }

let stabilize_model model =
  model.committed_a <- model.pending_a;
  model.committed_b <- model.pending_b;
  model.committed_choose_a <- model.pending_choose_a;
  let next = model_value model in
  let update =
    match model.observer_current with
    | None -> Some (Initialized next)
    | Some current ->
        if current = next then None else Some (Changed (current, next))
  in
  model.observer_current <- Some next;
  match update with
  | None -> ()
  | Some update ->
      model.observed_updates <- update :: model.observed_updates

let check_observed_updates label model actual_updates =
  Alcotest.(check (list observed_update))
    label (List.rev model.observed_updates) (List.rev !actual_updates)

let check_read label runtime read_current model =
  match model.observer_current with
  | None -> ()
  | Some expected ->
      Alcotest.(check int) label expected (run_ok runtime read_current)

let generate_trace ~seed ~steps =
  let random = Random.State.make [| seed |] in
  let next_value () = Random.State.int random 9 - 4 in
  let next_op index =
    if index mod 7 = 0 then Stabilize
    else
      match Random.State.int random 10 with
      | 0 | 1 | 2 -> Set_a (next_value ())
      | 3 | 4 | 5 -> Set_b (next_value ())
      | 6 | 7 -> Choose_a (Random.State.bool random)
      | 8 -> Read
      | _ -> Stabilize
  in
  let rec loop index acc =
    if index = steps then List.rev (Stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  Stabilize :: loop 1 []

let run_trace name ops =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source_a = Signal.Var.create 1 in
  let source_b = Signal.Var.create 10 in
  let choose_a = Signal.Var.create true in
  let sum =
    Signal.map2
      (fun left right -> left + right)
      (Signal.Var.watch source_a)
      (Signal.Var.watch source_b)
  in
  let selected =
    Signal.bind (Signal.Var.watch choose_a) (fun use_a ->
        if use_a then Signal.Var.watch source_a else Signal.Var.watch source_b)
  in
  let output =
    Signal.map2 (fun total selected -> (total * 10) + selected) sum selected
  in
  let actual_updates = ref [] in
  let record update =
    E.sync (fun () ->
        let observed =
          match update with
          | Signal.Initialized value -> Initialized value
          | Signal.Changed { old_value; new_value } ->
              Changed (old_value, new_value)
        in
        actual_updates := observed :: !actual_updates)
  in
  let observer = run_ok runtime (Signal.Observer.observe output record) in
  let model = create_model () in
  List.iteri
    (fun index op ->
      let label = Format.asprintf "%s step %d %a" name index pp_op op in
      match op with
      | Set_a value ->
          model.pending_a <- value;
          run_ok runtime (Signal.Var.set source_a value)
      | Set_b value ->
          model.pending_b <- value;
          run_ok runtime (Signal.Var.set source_b value)
      | Choose_a value ->
          model.pending_choose_a <- value;
          run_ok runtime (Signal.Var.set choose_a value)
      | Stabilize ->
          stabilize_model model;
          run_ok runtime Signal.stabilize;
          check_observed_updates label model actual_updates
      | Read ->
          check_read label runtime (Signal.Observer.read observer) model)
    ops;
  run_ok runtime (Signal.Observer.dispose observer)

let test_scripted_trace_matches_model () =
  run_trace "scripted"
    [
      Stabilize;
      Set_a 2;
      Set_a 3;
      Set_b 10;
      Stabilize;
      Read;
      Choose_a false;
      Set_a 99;
      Stabilize;
      Read;
      Set_b 4;
      Set_b 5;
      Choose_a true;
      Stabilize;
      Read;
    ]

let test_randomized_trace_matches_model () =
  List.iter
    (fun seed ->
      run_trace (Format.asprintf "seed-%d" seed) (generate_trace ~seed ~steps:80))
    [ 11; 29; 47; 83 ]

let () =
  Alcotest.run "eta_signal_model"
    [
      ( "model",
        [
          Alcotest.test_case "scripted trace matches model" `Quick
            test_scripted_trace_matches_model;
          Alcotest.test_case "randomized trace matches model" `Quick
            test_randomized_trace_matches_model;
        ] );
    ]
