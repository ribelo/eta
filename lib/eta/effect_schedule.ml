open Effect_core

module Sch = Schedule

let run_schedule_hook frame hook =
  let (_ : unit) = run_to_value frame hook in
  ()

let[@inline always] step_schedule frame run_hook input driver =
  Sch.step_with_hooks ~run_hook ~now_ms:(frame.runtime.now_ms ()) ~input !driver

let repeat ~schedule eff =
  preserve eff @@ fun frame ->
  try
    let run_iteration () = run_scope frame eff in
    let driver = ref (Sch.start ~random:frame.runtime.random schedule) in
    let run_hook = run_schedule_hook frame in
    let rec loop input =
      match step_schedule frame run_hook input driver with
      | Sch.Done metadata, _ -> ok metadata.output
      | Sch.Continue metadata, next_driver -> (
          driver := next_driver;
          frame.runtime.sleep metadata.delay;
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
  preserve eff @@ fun frame ->
  try
    let driver = ref (Sch.start ~random:frame.runtime.random schedule) in
    let run_hook = run_schedule_hook frame in
    let run_attempt () = run_scope frame eff in
    let rec loop () =
      match run_attempt () with
      | Exit.Ok _ as ok -> ok
      | Exit.Error (Cause.Fail err) when while_ err -> (
          match step_schedule frame run_hook err driver with
          | Sch.Continue metadata, next_driver ->
              driver := next_driver;
              frame.runtime.sleep metadata.delay;
              loop ()
          | Sch.Done _, _ -> error (Cause.Fail err))
      | Exit.Error _ as err -> err
    in
    loop ()
  with exn -> exit_of_exn frame exn

let retry_or_else ~schedule ~while_ ~or_else eff =
  preserve eff @@ fun frame ->
  try
    let driver = ref (Sch.start ~random:frame.runtime.random schedule) in
    let run_hook = run_schedule_hook frame in
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
                    match step_schedule frame run_hook err driver with
                    | Sch.Continue metadata, next_driver ->
                        driver := next_driver;
                        last_output := Some metadata.output;
                        frame.runtime.sleep metadata.delay;
                        loop ()
                    | Sch.Done metadata, _ ->
                        eval frame (or_else err (Some metadata.output))
                  else eval frame (or_else err !last_output)
              | None -> invalid_arg "Effect.retry_or_else: empty composite cause"))
    in
    loop ()
  with exn -> exit_of_exn frame exn
