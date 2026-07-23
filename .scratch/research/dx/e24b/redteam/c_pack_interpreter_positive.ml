type ('input, 'output) packed_schedule =
  | Schedule :
      ('input, 'output, 'hook) Eta.Schedule.t * ('hook -> unit) ->
      ('input, 'output) packed_schedule

type ('input, 'output) packed_driver =
  | Driver :
      ('input, 'output, 'hook) Eta.Schedule.driver * ('hook -> unit) ->
      ('input, 'output) packed_driver

let start (Schedule (schedule, run_hook)) =
  Driver (Eta.Schedule.start schedule, run_hook)

let step ~now_ms ~input (Driver (driver, run_hook)) =
  let decision, next =
    Eta.Schedule.step_with_hooks ~run_hook ~now_ms ~input driver
  in
  (decision, Driver (next, run_hook))

let () =
  let seen = ref [] in
  let schedule = Eta.Schedule.recurs 0 |> Eta.Schedule.tap_input Fun.id in
  let driver =
    start (Schedule (schedule, fun hook -> seen := hook :: !seen))
  in
  let decision, _ = step ~now_ms:0 ~input:7 driver in
  assert (!seen = [ 7 ]);
  (match decision with
  | Eta.Schedule.Done metadata -> assert (metadata.output = 0)
  | Eta.Schedule.Continue _ -> assert false);
  print_endline
    "packed two-parameter seam works only with interpreter bundled"
