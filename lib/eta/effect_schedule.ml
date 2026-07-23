open Effect_core

module Sch = Schedule

let[@inline always] step_schedule clock input driver =
  Sch.step ~now_ms:(clock#now_ms ()) ~input !driver

let repeat ~schedule eff =
  preserve ~leaf_name:"Effect.repeat"
    ~footprint:(footprint ~uses_clock:true ()) eff @@ fun frame ->
  try
    let clock = Runtime_core.current_clock frame.runtime in
    let random = Runtime_core.current_random frame.runtime in
    let run_iteration () = run_scope frame eff in
    let driver = ref (Sch.start ~random schedule) in
    let rec loop input =
      match step_schedule clock input driver with
      | Sch.Done metadata, _ -> ok metadata.output
      | Sch.Continue metadata, next_driver -> (
          driver := next_driver;
          clock#sleep metadata.delay;
          match run_iteration () with
          | Exit.Ok input -> loop input
          | Exit.Error _ as error -> error)
    in
    match run_iteration () with
    | Exit.Ok input -> loop input
    | Exit.Error _ as error -> error
  with exn -> exit_of_exn frame exn

let forever eff =
  repeat ~schedule:Sch.forever eff |> map (fun (_ : int) -> assert false)

let retry ~schedule ~while_ eff =
  preserve ~leaf_name:"Effect.retry"
    ~footprint:(footprint ~uses_clock:true ()) eff @@ fun frame ->
  try
    let clock = Runtime_core.current_clock frame.runtime in
    let random = Runtime_core.current_random frame.runtime in
    let driver = ref (Sch.start ~random schedule) in
    let run_attempt () = run_scope frame eff in
    let rec loop () =
      match run_attempt () with
      | Exit.Ok _ as ok -> ok
      | Exit.Error cause -> (
          match stripped_uncatchable cause with
          | Some _ -> error cause
          | None -> (
              match first_typed_failure cause with
              | Some err when while_ err -> (
                  match step_schedule clock err driver with
                  | Sch.Continue metadata, next_driver ->
                      driver := next_driver;
                      clock#sleep metadata.delay;
                      loop ()
                  | Sch.Done _, _ -> error cause)
              | Some _ -> error cause
              | None -> error cause))
    in
    loop ()
  with exn -> exit_of_exn frame exn

let retry_or_else ~schedule ~while_ ~or_else eff =
  preserve ~leaf_name:"Effect.retry_or_else"
    ~footprint:(footprint ~uses_clock:true ()) eff @@ fun frame ->
  try
    let clock = Runtime_core.current_clock frame.runtime in
    let random = Runtime_core.current_random frame.runtime in
    let driver = ref (Sch.start ~random schedule) in
    let last_output = ref None in
    let run_attempt () = run_scope frame eff in
    let rec loop () =
      match run_attempt () with
      | Exit.Ok _ as ok -> ok
      | Exit.Error cause -> (
          match stripped_uncatchable cause with
          | Some cause -> error cause
          | None -> (
              match first_typed_failure cause with
              | Some err ->
                  if while_ err then
                    match step_schedule clock err driver with
                    | Sch.Continue metadata, next_driver ->
                        driver := next_driver;
                        last_output := Some metadata.output;
                        clock#sleep metadata.delay;
                        loop ()
                    | Sch.Done metadata, _ ->
                        eval frame (or_else err (Some metadata.output))
                  else eval frame (or_else err !last_output)
              | None -> invalid_arg "Effect.retry_or_else: empty composite cause"))
    in
    loop ()
  with exn -> exit_of_exn frame exn
