module E = Eta.Effect
module Signal = Eta_signal.Make_no_error ()

exception Model_failure of string

type observed_update =
  | Initialized of int
  | Changed of int * int

type op =
  | Set_a of int
  | Set_b of int
  | Choose_a of bool
  | Observe
  | Dispose
  | Stabilize
  | Read

type model = {
  mutable pending_a : int;
  mutable pending_b : int;
  mutable pending_choose_a : bool;
  mutable committed_a : int;
  mutable committed_b : int;
  mutable committed_choose_a : bool;
  mutable observer_active : bool;
  mutable observer_current : int option;
  mutable observed_updates : observed_update list;
}

type test_error =
  [ Signal.graph_error | Signal.observer_read_error | Signal.stabilize_error ]

let failf format = Format.kasprintf (fun message -> raise (Model_failure message)) format

let pp_hidden formatter _ = Format.pp_print_string formatter "<signal-error>"

let pp_observed_update formatter = function
  | Initialized value -> Format.fprintf formatter "Initialized %d" value
  | Changed (old_value, new_value) ->
      Format.fprintf formatter "Changed (%d, %d)" old_value new_value

let pp_observed_updates formatter updates =
  Format.fprintf formatter "[%a]"
    (Format.pp_print_list
       ~pp_sep:(fun formatter () -> Format.fprintf formatter "; ")
       pp_observed_update)
    updates

let pp_op formatter = function
  | Set_a value -> Format.fprintf formatter "Set_a %d" value
  | Set_b value -> Format.fprintf formatter "Set_b %d" value
  | Choose_a value -> Format.fprintf formatter "Choose_a %b" value
  | Observe -> Format.pp_print_string formatter "Observe"
  | Dispose -> Format.pp_print_string formatter "Dispose"
  | Stabilize -> Format.pp_print_string formatter "Stabilize"
  | Read -> Format.pp_print_string formatter "Read"

let pp_trace formatter ops =
  Format.fprintf formatter "[%a]"
    (Format.pp_print_list
       ~pp_sep:(fun formatter () -> Format.fprintf formatter "; ")
       pp_op)
    ops

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let run_ok : type a. test_error Eta.Runtime.t -> (a, [< test_error ]) E.t -> a =
 fun runtime eff ->
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failf "expected Ok, got %a" (Eta.Cause.pp pp_hidden) cause

let expect_uninitialized label runtime eff =
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Error (Eta.Cause.Fail `Uninitialized_observer) -> ()
  | Eta.Exit.Error cause ->
      failf "%s: expected Uninitialized_observer, got %a" label
        (Eta.Cause.pp pp_hidden) cause
  | Eta.Exit.Ok _ ->
      failf "%s: expected Uninitialized_observer, got Ok" label

let observed_of_signal_update = function
  | Signal.Initialized value -> Initialized value
  | Signal.Changed { old_value; new_value } -> Changed (old_value, new_value)

let create_model () =
  {
    pending_a = 1;
    pending_b = 10;
    pending_choose_a = true;
    committed_a = 1;
    committed_b = 10;
    committed_choose_a = true;
    observer_active = false;
    observer_current = None;
    observed_updates = [];
  }

let model_value model =
  let selected =
    if model.committed_choose_a then model.committed_a else model.committed_b
  in
  ((model.committed_a + model.committed_b) * 10) + selected

let model_observe model =
  if not model.observer_active then (
    model.observer_active <- true;
    model.observer_current <- None)

let model_dispose model =
  if model.observer_active then (
    model.observer_active <- false;
    model.observer_current <- None)

let stabilize_model model =
  model.committed_a <- model.pending_a;
  model.committed_b <- model.pending_b;
  model.committed_choose_a <- model.pending_choose_a;
  if model.observer_active then (
    let next = model_value model in
    let update =
      match model.observer_current with
      | None -> Some (Initialized next)
      | Some current ->
          if Int.equal current next then None else Some (Changed (current, next))
    in
    model.observer_current <- Some next;
    Option.iter
      (fun update -> model.observed_updates <- update :: model.observed_updates)
      update)

let check_eq_int label expected actual =
  if not (Int.equal expected actual) then
    failf "%s: expected %d, got %d" label expected actual

let check_observed_updates label model actual_updates =
  let expected = List.rev model.observed_updates in
  let actual = List.rev !actual_updates in
  if expected <> actual then
    failf "%s updates mismatch\nexpected: %a\nactual:   %a" label
      pp_observed_updates expected pp_observed_updates actual

let check_read label runtime observer model =
  match (observer, model.observer_active, model.observer_current) with
  | None, _, _ -> ()
  | Some actual_observer, true, Some expected ->
      let actual = run_ok runtime (Signal.Observer.read actual_observer) in
      check_eq_int label expected actual
  | Some actual_observer, true, None ->
      expect_uninitialized label runtime (Signal.Observer.read actual_observer)
  | Some _, false, _ -> ()

let observe runtime output actual_updates =
  let record update =
    E.sync (fun () ->
        actual_updates := observed_of_signal_update update :: !actual_updates)
  in
  run_ok runtime (Signal.Observer.observe output record)

let dispose runtime observer =
  Option.iter
    (fun observer -> run_ok runtime (Signal.Observer.dispose observer))
    observer

let with_runtime stdenv f =
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  f runtime

let run_trace stdenv ops =
  with_runtime stdenv @@ fun runtime ->
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
  let model = create_model () in
  let actual_updates = ref [] in
  let actual_observer = ref None in
  let ops = Observe :: Stabilize :: ops @ [ Stabilize; Read; Dispose ] in
  List.iteri
    (fun index op ->
      let label =
        Format.asprintf "step %d %a\ntrace: %a" index pp_op op pp_trace ops
      in
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
      | Observe ->
          if Option.is_none !actual_observer then
            actual_observer := Some (observe runtime output actual_updates);
          model_observe model
      | Dispose ->
          dispose runtime !actual_observer;
          actual_observer := None;
          model_dispose model
      | Stabilize ->
          stabilize_model model;
          run_ok runtime Signal.stabilize;
          check_observed_updates label model actual_updates
      | Read -> check_read label runtime !actual_observer model)
    ops

let trace_failure stdenv ops =
  try
    run_trace stdenv ops;
    None
  with
  | Model_failure message -> Some message
  | exn -> Some (Printexc.to_string exn)

let op_simplifications = function
  | Set_a value when value <> 0 -> [ Set_a 0 ]
  | Set_b value when value <> 0 -> [ Set_b 0 ]
  | Choose_a false -> [ Choose_a true ]
  | Observe -> [ Stabilize ]
  | Dispose -> [ Stabilize ]
  | Read -> [ Stabilize ]
  | Set_a _ | Set_b _ | Choose_a true | Stabilize -> []

let replace_at index replacement ops =
  List.mapi (fun current op -> if current = index then replacement else op) ops

let remove_range start length ops =
  ops
  |> List.mapi (fun index op ->
         if index >= start && index < start + length then None else Some op)
  |> List.filter_map Fun.id

let rec first_some = function
  | [] -> None
  | f :: rest -> (
      match f () with
      | None -> first_some rest
      | Some _ as result -> result)

let shrink_by_deletion stdenv ops =
  let rec try_chunk size =
    if size = 0 then None
    else
      let rec try_start start =
        if start >= List.length ops then try_chunk (size / 2)
        else
          let candidate = remove_range start size ops in
          match trace_failure stdenv candidate with
          | None -> try_start (start + 1)
          | Some _ -> Some candidate
      in
      try_start 0
  in
  try_chunk (max 1 (List.length ops / 2))

let shrink_by_simplification stdenv ops =
  ops
  |> List.mapi (fun index op ->
         fun () ->
           op_simplifications op
           |> List.find_map (fun replacement ->
                  let candidate = replace_at index replacement ops in
                  match trace_failure stdenv candidate with
                  | None -> None
                  | Some _ -> Some candidate))
  |> first_some

let shrink_trace stdenv ops =
  let rec loop ops =
    match shrink_by_deletion stdenv ops with
    | Some smaller -> loop smaller
    | None -> (
        match shrink_by_simplification stdenv ops with
        | Some simpler -> loop simpler
        | None -> ops)
  in
  loop ops

let generate_trace ~seed ~steps =
  let random = Random.State.make [| seed; steps; 0x51A1 |] in
  let next_value () = Random.State.int random 17 - 8 in
  let next_op index =
    if index mod 9 = 0 then Stabilize
    else
      match Random.State.int random 16 with
      | 0 | 1 | 2 | 3 -> Set_a (next_value ())
      | 4 | 5 | 6 | 7 -> Set_b (next_value ())
      | 8 | 9 -> Choose_a (Random.State.bool random)
      | 10 -> Observe
      | 11 -> Dispose
      | 12 | 13 -> Read
      | _ -> Stabilize
  in
  List.init steps next_op

let parse_args () =
  let seeds = ref 50 in
  let steps = ref 80 in
  let start_seed = ref 0 in
  let specs =
    [
      ("--seeds", Arg.Set_int seeds, "number of generated seeds to run");
      ("--steps", Arg.Set_int steps, "operations generated for each seed");
      ("--start-seed", Arg.Set_int start_seed, "first seed to run");
    ]
  in
  Arg.parse specs
    (fun arg -> raise (Arg.Bad (Format.asprintf "unexpected argument %S" arg)))
    "fuzz_eta_signal_model [--seeds N] [--steps N] [--start-seed N]";
  if !seeds < 0 then invalid_arg "--seeds must be >= 0";
  if !steps < 0 then invalid_arg "--steps must be >= 0";
  (!start_seed, !seeds, !steps)

let run_fuzz stdenv =
  let start_seed, seeds, steps = parse_args () in
  for offset = 0 to seeds - 1 do
    let seed = start_seed + offset in
    let ops = generate_trace ~seed ~steps in
    match trace_failure stdenv ops with
    | None -> ()
    | Some message ->
        let shrunk = shrink_trace stdenv ops in
        let shrunk_message =
          match trace_failure stdenv shrunk with
          | Some message -> message
          | None -> message
        in
        Format.eprintf
          "signal model fuzz failed seed=%d steps=%d\n%s\nshrunk trace: %a\n%!"
          seed steps shrunk_message pp_trace shrunk;
        exit 1
  done

let () = Eio_main.run run_fuzz
