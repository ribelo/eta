type hook =
  | Left_input of int
  | Left_output of int
  | Right_input of int
  | Right_output of int

type top_observation =
  | Driver_input of int
  | Driver_output of string

let rec drive_plan acc = function
  | Eta.Schedule.Hook (hook, resume) -> drive_plan (hook :: acc) (resume ())
  | Eta.Schedule.Complete (decision, driver) ->
      (List.rev acc, decision, driver)

let output_label = function
  | Eta.Schedule.First_phase output -> Printf.sprintf "first:%d" output
  | Eta.Schedule.Second_phase output -> Printf.sprintf "second:%d" output

let () =
  let left =
    Eta.Schedule.recurs 0
    |> Eta.Schedule.tap_output (fun output -> Left_output output)
    |> Eta.Schedule.tap_input (fun input -> Left_input input)
  in
  let right =
    Eta.Schedule.recurs 0
    |> Eta.Schedule.tap_output (fun output -> Right_output output)
    |> Eta.Schedule.tap_input (fun input -> Right_input input)
  in
  let hooks, decision, _ =
    Eta.Schedule.and_then left right
    |> Eta.Schedule.start
    |> Eta.Schedule.step_plan ~now_ms:0 ~input:7
    |> drive_plan []
  in
  let expected =
    [ Left_input 7; Left_output 0; Right_input 7; Right_output 0 ]
  in
  assert (hooks = expected);
  (match decision with
  | Eta.Schedule.Done metadata ->
      assert (metadata.output = Eta.Schedule.Second_phase 0)
  | Eta.Schedule.Continue _ -> assert false);

  (* Strongest minimal B: one pre-step and one post-step observer around the
     same top-level driver call. It cannot see either left terminal output or
     the right pre-step that occurs during And_then's phase handoff. *)
  let top_observations = ref [ Driver_input 7 ] in
  let decision, _ =
    Eta.Schedule.and_then (Eta.Schedule.recurs 0) (Eta.Schedule.recurs 0)
    |> Eta.Schedule.start
    |> Eta.Schedule.step ~now_ms:0 ~input:7
  in
  let metadata =
    match decision with
    | Eta.Schedule.Done metadata | Eta.Schedule.Continue metadata -> metadata
  in
  top_observations :=
    !top_observations @ [ Driver_output (output_label metadata.output) ];
  assert
    (!top_observations = [ Driver_input 7; Driver_output "second:0" ]);
  assert (List.length hooks = 4);
  assert (List.length !top_observations = 2);

  (* Direct step_with_hooks evidence: an interpreter failure yields no next
     driver. Reusing the caller-owned original driver repeats attempt one. *)
  let failed_driver = Eta.Schedule.start left in
  let failure_seen = ref false in
  (try
     ignore
       (Eta.Schedule.step_with_hooks
          ~run_hook:(fun _ ->
            failure_seen := true;
            failwith "hook failed")
          ~now_ms:0 ~input:11 failed_driver)
   with Failure _ -> ());
  assert !failure_seen;
  let retried_hooks, retried_decision, _ =
    Eta.Schedule.step_plan ~now_ms:0 ~input:11 failed_driver |> drive_plan []
  in
  assert (retried_hooks = [ Left_input 11; Left_output 0 ]);
  (match retried_decision with
  | Eta.Schedule.Done metadata ->
      assert (metadata.output = 0);
      assert (metadata.attempt = 1)
  | Eta.Schedule.Continue _ -> assert false);

  print_endline "A hooks in one public and_then step: 4";
  print_endline "B minimal top-level before/after observations: 2";
  print_endline
    "step_with_hooks failure returned no advanced driver; retry attempt: 1"
