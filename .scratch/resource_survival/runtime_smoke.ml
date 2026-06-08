open Effet
open Common

module type RESOURCE = sig
  type ('env, 'err, 'a) t

  val manual :
    ('env, 'err, 'a) Effect.t -> ('env, 'err, ('env, 'err, 'a) t) Effect.t

  val auto :
    ?on_error:('err -> unit) ->
    load:('env, 'err, 'a) Effect.t ->
    schedule:Schedule.t ->
    unit ->
    ('env, 'err, ('env, 'err, 'a) t) Effect.t

  val get : ('env, 'err, 'a) t -> ('env, 'err, 'a) Effect.t
  val refresh : ('env, 'err, 'a) t -> ('env, 'err, unit) Effect.t
  val failures : ('env, 'err, 'a) t -> ('env, 'outer_err, 'err Cause.t list) Effect.t
end

let test_manual_refresh label (module R : RESOURCE) =
  with_runtime @@ fun rt ->
  let source = ref 0 in
  let load = Effect.sync (label ^ ".load") (fun _ -> !source) in
  let eff =
    R.manual load
    |> Effect.bind (fun resource ->
           R.get resource
           |> Effect.bind (fun initial ->
                  Effect.sync (label ^ ".set") (fun _ -> source := 1)
                  |> Effect.bind (fun () -> R.refresh resource)
                  |> Effect.bind (fun () -> R.get resource)
                  |> Effect.map (fun refreshed -> (initial, refreshed))))
  in
  let initial, refreshed = run_ok rt eff in
  check_int (label ^ " initial") 0 initial;
  check_int (label ^ " refreshed") 1 refreshed

let test_failed_refresh_keeps_cached_value label (module R : RESOURCE) =
  with_runtime @@ fun rt ->
  let source = ref (Ok 0) in
  let load =
    Effect.sync (label ^ ".load") (fun _ -> !source)
    |> Effect.bind (function
         | Ok value -> Effect.pure value
         | Error message -> Effect.fail (`Refresh_failed message))
  in
  let eff =
    R.manual load
    |> Effect.bind (fun resource ->
           Effect.sync (label ^ ".fail") (fun _ -> source := Error "boom")
           |> Effect.bind (fun () -> R.refresh resource)
           |> Effect.catch (fun (`Refresh_failed _ : [ `Refresh_failed of string ]) ->
                  Effect.unit)
           |> Effect.bind (fun () -> R.get resource))
  in
  check_int (label ^ " kept") 0 (run_ok rt eff)

let test_auto_refreshes_on_schedule label (module R : RESOURCE) =
  with_test_clock @@ fun clock rt ->
  let source = ref 0 in
  let load =
    Effect.sync (label ^ ".auto.load") (fun _ ->
        incr source;
        !source)
  in
  let resource =
    run_ok rt (R.auto ~load ~schedule:(Schedule.spaced (Duration.ms 5)) ())
  in
  check_int (label ^ " initial") 1 (run_ok rt (R.get resource));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  check_int (label ^ " first refresh") 2 (run_ok rt (R.get resource));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  check_int (label ^ " second refresh") 3 (run_ok rt (R.get resource))

let test_auto_failed_refresh_keeps_cached_value label (module R : RESOURCE) =
  with_test_clock @@ fun clock rt ->
  let results = ref [ Ok 1; Error "boom"; Ok 2 ] in
  let load =
    Effect.sync (label ^ ".auto.load") (fun _ ->
        match !results with
        | [] -> Ok 999
        | result :: rest ->
            results := rest;
            result)
    |> Effect.bind (function
         | Ok value -> Effect.pure value
         | Error message -> Effect.fail (`Refresh_failed message))
  in
  let errors = ref [] in
  let resource =
    run_ok rt
      (R.auto ~load ~schedule:(Schedule.spaced (Duration.ms 5))
         ~on_error:(fun err -> errors := err :: !errors) ())
  in
  check_int (label ^ " initial") 1 (run_ok rt (R.get resource));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  check_int (label ^ " failed refresh keeps old value") 1
    (run_ok rt (R.get resource));
  check_strings (label ^ " on_error") [ "boom" ]
    (List.map (fun (`Refresh_failed message) -> message) (List.rev !errors));
  (match run_ok rt (R.failures resource) with
  | [ Cause.Fail (`Refresh_failed "boom") ] -> ()
  | _ -> failwith (label ^ ": expected failure sink"));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  check_int (label ^ " subsequent refresh updates") 2
    (run_ok rt (R.get resource))

let run_suite label resource =
  test_manual_refresh label resource;
  test_failed_refresh_keeps_cached_value label resource;
  test_auto_refreshes_on_schedule label resource;
  test_auto_failed_refresh_keeps_cached_value label resource

let () =
  run_suite "branch-a" (module Branch_a_resource : RESOURCE);
  run_suite "branch-b" (module Branch_b_atomic : RESOURCE);
  print_endline "resource_survival runtime smoke passed"
