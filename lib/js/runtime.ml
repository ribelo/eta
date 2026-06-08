type 'err t = 'err Runtime_core.t

let create = Runtime_core.create

let context runtime =
  let fiber = Runtime_fiber.create_root ~scheduler:runtime.Runtime_core.scheduler in
  ( {
      Effect_core.scheduler = runtime.scheduler;
      fiber;
      clock = runtime.clock;
      daemon_started = (fun () -> Runtime_core.daemon_started runtime);
      daemon_finished = (fun () -> Runtime_core.daemon_finished runtime);
      daemon_failed = Runtime_core.daemon_failed runtime;
    },
    fiber )

let run_promise runtime eff =
  let context, fiber = context runtime in
  Js.Promise.then_
    (fun exit ->
      Runtime_fiber.finish fiber (Runtime_fiber.Exit exit);
      Js.Promise.resolve exit)
    (Effect_core.run_promise context eff)

let run_now runtime eff =
  let context, fiber = context runtime in
  match Effect_core.run_now context eff with
  | None -> None
  | Some exit ->
      Runtime_fiber.finish fiber (Runtime_fiber.Exit exit);
      Some exit

let drain_promise = Runtime_core.drain_promise
