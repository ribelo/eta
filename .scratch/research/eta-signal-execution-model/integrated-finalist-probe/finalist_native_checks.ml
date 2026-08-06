module E = Eta.Effect

module Observer_error = struct
  type t = [ `Injected ]

  let pp ppf `Injected = Format.pp_print_string ppf "injected"
end

module Finalist = Selected_factory_fresh.Make (Observer_error) ()

type error =
  [ Finalist.graph_error
  | Finalist.observer_read_error
  | Finalist.stabilize_error ]

let widen (effect : ('a, [< error ]) E.t) : ('a, error) E.t =
  E.map_error (fun error -> (error :> error)) effect

let run_ok runtime effect =
  match Eta.Runtime.run runtime (widen effect) with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected success, got %a"
        (Eta.Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<typed>"))
        cause

let expect_defect runtime effect =
  match Eta.Runtime.run runtime (widen effect) with
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected defect, got %a"
        (Eta.Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<typed>"))
        cause
  | Eta.Exit.Ok _ -> Alcotest.fail "expected defect, got success"

let test_failed_attempt_preserves_snapshot runtime =
  let source = Finalist.Var.create 0 in
  let fail = ref false in
  let output =
    Finalist.map
      (fun value -> if !fail then failwith "injected pure failure" else value)
      (Finalist.Var.watch source)
  in
  let observer = run_ok runtime (Finalist.Observer.observe output) in
  run_ok runtime Finalist.stabilize;
  Alcotest.(check int) "initial" 0
    (run_ok runtime (Finalist.Observer.read observer));
  run_ok runtime (Finalist.Var.set source 1);
  fail := true;
  expect_defect runtime Finalist.stabilize;
  Alcotest.(check int) "committed snapshot retained" 0
    (run_ok runtime (Finalist.Observer.read observer));
  fail := false;
  run_ok runtime Finalist.stabilize;
  Alcotest.(check int) "retry publishes admitted source" 1
    (run_ok runtime (Finalist.Observer.read observer))

let test_observer_dependency_order runtime =
  let source = Finalist.Var.create 0 in
  let parent = Finalist.map (( + ) 1) (Finalist.Var.watch source) in
  let child = Finalist.map (( + ) 1) parent in
  let trace = ref [] in
  ignore
    (run_ok runtime
       (Finalist.Observer.observe parent ~on_update:(fun _ ->
            trace := "parent" :: !trace;
            E.unit)));
  ignore
    (run_ok runtime
       (Finalist.Observer.observe child ~on_update:(fun _ ->
            trace := "child" :: !trace;
            E.unit)));
  run_ok runtime Finalist.stabilize;
  Alcotest.(check (list string))
    "dependency before consumer" [ "parent"; "child" ] (List.rev !trace)

let test_disposal_is_idempotent runtime =
  let finishes = ref 0 in
  let observer =
    run_ok runtime
      (Finalist.Observer.observe (Finalist.const 1)
         ~on_finish:(function
           | `Disposed -> incr finishes
           | `Invalid_scope -> ()))
  in
  run_ok runtime (Finalist.Observer.dispose observer);
  run_ok runtime (Finalist.Observer.dispose observer);
  Alcotest.(check int) "one finish" 1 !finishes

let () =
  Eio_main.run @@ fun environment ->
  Eio.Switch.run @@ fun switch ->
  let runtime =
    Eta_eio.Runtime.create ~sw:switch ~clock:(Eio.Stdenv.clock environment) ()
  in
  Alcotest.run "integrated finalist native replacements"
    [
      ( "private-observation replacements",
        [
          Alcotest.test_case "rollback and retry" `Quick (fun () ->
              test_failed_attempt_preserves_snapshot runtime);
          Alcotest.test_case "observer dependency order" `Quick (fun () ->
              test_observer_dependency_order runtime);
          Alcotest.test_case "idempotent disposal" `Quick (fun () ->
              test_disposal_is_idempotent runtime);
        ] );
    ]
