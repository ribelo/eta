type event =
  | Attempt of int
  | Continue of int
  | Done of int

let run_retry_recipe ~failures ~retries =
  let events = ref [] in
  let rec loop attempt driver =
    events := Attempt attempt :: !events;
    if attempt > failures then (`Ok attempt, List.rev !events)
    else
      match Eta.Schedule.step ~now_ms:attempt ~input:attempt driver with
      | Eta.Schedule.Continue metadata, next ->
          events := Continue metadata.output :: !events;
          loop (attempt + 1) next
      | Eta.Schedule.Done metadata, _ ->
          events := Done metadata.output :: !events;
          (`Exhausted, List.rev !events)
  in
  loop 1 (Eta.Schedule.start (Eta.Schedule.recurs retries))

let () =
  (* D's strongest ordinary-code recipe: observe the process operation itself,
     not the schedule. A custom retry loop can log every attempt without taps. *)
  let result, events = run_retry_recipe ~failures:2 ~retries:2 in
  assert (result = `Ok 3);
  assert
    (events =
     [ Attempt 1; Continue 0; Attempt 2; Continue 1; Attempt 3 ]);

  (* The same recipe cannot recover structural events hidden inside one
     [and_then] step. With taps deleted, only the outer second-phase result is
     observable to ordinary code. *)
  let decision, _ =
    Eta.Schedule.and_then (Eta.Schedule.recurs 0) (Eta.Schedule.recurs 0)
    |> Eta.Schedule.start |> Eta.Schedule.step ~now_ms:0 ~input:7
  in
  (match decision with
  | Eta.Schedule.Done metadata ->
      assert (metadata.output = Eta.Schedule.Second_phase 0)
  | Eta.Schedule.Continue _ -> assert false);

  print_endline "D recipe: top-level retry attempts are observable without taps";
  print_endline
    "D limit: branch-local and_then events are not recoverable without a structural protocol"
