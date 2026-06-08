(* Runtime smoke tests for each candidate shape.
   Confirms the interpreter sketches in the lab actually run. *)

open Fiber_research

let test_f_a_par_collects_results () =
  Eio_main.run @@ fun _ ->
  let open F_a_collection.Effect in
  match run ~env:() (par (pure 1) (pure 2)) with
  | Ok (1, 2) -> print_endline "F-A par: ok"
  | Ok _ -> failwith "F-A par: wrong values"
  | Error _ -> failwith "F-A par: unexpected error"

let test_f_a_all_in_order () =
  Eio_main.run @@ fun _ ->
  let open F_a_collection.Effect in
  match run ~env:() (all [ pure 1; pure 2; pure 3 ]) with
  | Ok [ 1; 2; 3 ] -> print_endline "F-A all: ok"
  | Ok _ -> failwith "F-A all: wrong order"
  | Error _ -> failwith "F-A all: unexpected error"

let test_f_a_par_fail_fast () =
  Eio_main.run @@ fun _ ->
  let open F_a_collection.Effect in
  match run ~env:() (par (fail `Boom) (pure 99)) with
  | Error `Boom -> print_endline "F-A par fail-fast: ok"
  | _ -> failwith "F-A par fail-fast: did not propagate"

let test_f_b_fork_await_roundtrip () =
  Eio_main.run @@ fun _ ->
  let open F_b_public_fiber.Effect in
  let prog =
    let* f = fork (pure 7) in
    await f
  in
  match run ~env:() prog with
  | Ok 7 -> print_endline "F-B fork+await: ok"
  | _ -> failwith "F-B fork+await: failed"

let test_f_b_typed_error_through_await () =
  Eio_main.run @@ fun _ ->
  let open F_b_public_fiber.Effect in
  let prog =
    let* f = fork (fail `Boom) in
    await f
  in
  match run ~env:() prog with
  | Error `Boom -> print_endline "F-B typed err through await: ok"
  | _ -> failwith "F-B typed err: did not propagate"

let test_f_c_scoped_fork_await () =
  Eio_main.run @@ fun _ ->
  let open F_c_hybrid.Effect in
  let prog =
    scoped {
      run = fun (type s) () : (s, unit, _, int) scoped_t ->
        let** (f : (s, _, int) fiber) = fork (s_pure 11) in
        await f
    }
  in
  match run ~env:() prog with
  | Ok 11 -> print_endline "F-C scoped fork+await: ok"
  | _ -> failwith "F-C scoped: failed"

let () =
  test_f_a_par_collects_results ();
  test_f_a_all_in_order ();
  test_f_a_par_fail_fast ();
  test_f_b_fork_await_roundtrip ();
  test_f_b_typed_error_through_await ();
  test_f_c_scoped_fork_await ();
  print_endline "all runtime smoke tests passed"
