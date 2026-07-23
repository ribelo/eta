type ('input, 'output) packed_driver =
  | Driver :
      ('input, 'output, 'hook) Eta.Schedule.driver ->
      ('input, 'output) packed_driver

(* A caller-supplied interpreter cannot consume the hidden hook type. *)
let step ~run_hook ~now_ms ~input (Driver driver) =
  let decision, next =
    Eta.Schedule.step_with_hooks ~run_hook ~now_ms ~input driver
  in
  (decision, Driver next)
