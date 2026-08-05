module S = Eta_signal.Make (Eta_signal.No_observer_error) ()
module Signal_map = Eta_signal_map.Make (S.Package)
module M = Eta_signal_map.Map.Make (Int)
module Keyed = Signal_map.Keyed (Int)

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

let render_pair (value, keyed) =
  let bindings =
    M.fold (fun key data acc -> (key, data) :: acc) keyed [] |> List.rev
  in
  Printf.sprintf "%d|%s" value
    (String.concat ","
       (List.map (fun (key, data) -> Printf.sprintf "%d:%d" key data) bindings))

let run_script ~diagnostic ops =
  let open Eta.Syntax in
  let program =
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
    let die _error = Failure "signal script effect failed" in
    let* observer =
      S.Observer.observe combined ~on_update:(fun _ -> Eta.Effect.unit)
      |> Eta.Effect.or_die die
    in
    let apply op =
      match op with
      | Set_source value -> S.Var.set source value
      | Switch flag -> S.Var.set selector flag
      | Put (key, data) ->
          S.Var.set input (M.set (key mod 3) data (S.Var.value input))
      | Drop key -> S.Var.set input (M.remove (key mod 3) (S.Var.value input))
    in
    let step op =
      let* () = apply op |> Eta.Effect.or_die die in
      let* () = S.stabilize |> Eta.Effect.or_die die in
      let* value = S.Observer.read observer |> Eta.Effect.or_die die in
      trace := render_pair value :: !trace;
      if diagnostic then (
        let* _stats = S.stats () |> Eta.Effect.or_die die in
        let* dot = S.to_dot () |> Eta.Effect.or_die die in
        if string_contains ~needle:(string_of_int sentinel) dot then
          dot_value_free := false;
        Eta.Effect.unit)
      else Eta.Effect.unit
    in
    let rec loop = function
      | [] -> Eta.Effect.unit
      | op :: rest ->
          let* () = step op in
          loop rest
    in
    let* () = loop ops in
    let* () = S.Observer.dispose observer |> Eta.Effect.or_die die in
    let* () = S.stabilize |> Eta.Effect.or_die die in
    Eta.Effect.pure (List.rev !trace, !dot_value_free)
  in
  Eta_test.Run.run program

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
    QCheck.(make Gen.(list_size (int_range 0 12) op_gen))
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
