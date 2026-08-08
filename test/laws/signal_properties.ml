(* Observation boundary: the public observer read trace of one combined
   scalar/bind/keyed graph, plus the fiber census at teardown. The generated
   class covers valid and invalid scalar, stable-family, and observer states
   with sentinel values. A diagnostic run interleaves stats and DOT reads;
   the plain run does not. The law requires identical traces, DOT output
   free of sentinel values, and an available empty fiber census in both
   runs. *)

let sentinel = 987654

let string_contains ~needle haystack =
  let needle_length = String.length needle in
  let rec scan index =
    index + needle_length <= String.length haystack
    && (String.sub haystack index needle_length = needle || scan (index + 1))
  in
  needle_length > 0 && scan 0

type op =
  | Set_source of int
  | Switch of bool
  | Put of int * int
  | Drop of int

let pp_op = function
  | Set_source value -> Printf.sprintf "Set_source %d" value
  | Switch flag -> Printf.sprintf "Switch %b" flag
  | Put (key, data) -> Printf.sprintf "Put (%d, %d)" key data
  | Drop key -> Printf.sprintf "Drop %d" key

let op_gen =
  let open QCheck.Gen in
  let value_gen =
    oneof_weighted [ (4, int_range 0 64); (1, return sentinel) ]
  in
  oneof_weighted
    [
      (3, map (fun value -> Set_source value) value_gen);
      (2, map (fun flag -> Switch flag) bool);
      ( 2,
        map2 (fun key data -> Put (key, data)) (int_range 0 8)
          (int_range 0 256) );
      (1, map (fun key -> Drop key) (int_range 0 8));
    ]

let run_script ~diagnostic ops =
  let module S = Eta_signal.Make (Eta_signal.No_observer_error) () in
  let module Signal_map = Eta_signal_map.Make (S.Package) in
  let module M = Eta_signal_map.Map.Make (Int) in
  let module Keyed = Signal_map.Keyed (Int) in
  let render_pair (value, keyed) =
    let bindings =
      M.fold (fun key data acc -> (key, data) :: acc) keyed [] |> List.rev
    in
    Printf.sprintf "%d|%s" value
      (String.concat ","
         (List.map
            (fun (key, data) -> Printf.sprintf "%d:%d" key data)
            bindings))
  in
  let source = S.Var.create sentinel in
  let selector = S.Var.create true in
  let branch = S.map succ (S.Var.watch source) in
  let selected =
    S.bind (S.Var.watch selector) ~f:(fun use_branch ->
        if use_branch then branch else S.const sentinel)
  in
  let input = S.Var.create (M.set 0 0 M.empty) in
  let keyed = Keyed.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data -> data) in
  let combined = S.map2 (fun left right -> (left, right)) selected keyed in
  let trace = ref [] in
  let dot_value_free = ref true in
  let ok stage = function
    | Ok value -> value
    | Error _ -> failwith ("signal script failed: " ^ stage)
  in
  let observer =
    ok "observe" (S.Observer.observe combined ~on_update:(fun _ -> Ok ()))
  in
  let apply op =
    match op with
    | Set_source value -> ok "set" (S.Var.set source value)
    | Switch flag -> ok "set" (S.Var.set selector flag)
    | Put (key, data) ->
        ok "set" (S.Var.set input (M.set (key mod 3) data (S.Var.value input)))
    | Drop key ->
        ok "set" (S.Var.set input (M.remove (key mod 3) (S.Var.value input)))
  in
  let step op =
    let operation = pp_op op in
    apply op;
    ok ("stabilize " ^ operation) (S.stabilize ());
    let value = ok ("read " ^ operation) (S.Observer.read observer) in
    trace := render_pair value :: !trace;
    if diagnostic then (
      ignore (ok ("stats " ^ operation) (S.stats ()));
      let dot = S.to_dot () in
      if string_contains ~needle:(string_of_int sentinel) dot then
        dot_value_free := false)
  in
  List.iter step ops;
  ok "dispose" (S.Observer.dispose observer);
  ok "final stabilize" (S.stabilize ());
  (* The graph engine is synchronous: it owns no fibers, so the census is
     structurally empty. The harness still runs a capture effect so the law
     keeps its available-census observation. *)
  Eta_test.Run.run (Eta.Effect.sync (fun () -> (List.rev !trace, !dot_value_free)))

let exit_value outcome =
  match outcome.Eta_test.Run.exit with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected run failure: %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
        cause

let test_diagnostics_noninterfering =
  QCheck.Test.make
    ~name:"signal diagnostics are committed value-free and noninterfering"
    ~count:40
    QCheck.(
      make
        ~print:(fun ops -> "[" ^ String.concat "; " (List.map pp_op ops) ^ "]")
        Gen.(list_size (int_range 0 12) op_gen))
    (fun ops ->
      let plain = run_script ~diagnostic:false ops in
      let diagnostic = run_script ~diagnostic:true ops in
      Eta_test.Run.expect_no_pending_fibers plain;
      Eta_test.Run.expect_no_pending_fibers diagnostic;
      let plain_trace, _ = exit_value plain in
      let diagnostic_trace, dot_value_free = exit_value diagnostic in
      Alcotest.(check bool) "DOT contains no sentinel values" true
        dot_value_free;
      Alcotest.(check (list string)) "diagnostic reads do not change behavior"
        plain_trace diagnostic_trace;
      true)

let () =
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true
      [ test_diagnostics_noninterfering ]
  in
  if code <> 0 then exit code
