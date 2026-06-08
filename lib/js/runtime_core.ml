type timer_cancel = unit -> unit

type clock = {
  now_ms : unit -> int;
  sleep : Duration.t -> (unit -> unit) -> timer_cancel;
}

let default_clock () =
  {
    now_ms = (fun () -> int_of_float (Js_interop.date_now ()));
    sleep =
      (fun duration callback ->
        let timeout =
          Js_interop.set_timeout callback (Duration.to_ms duration)
        in
        fun () -> Js_interop.clear_timeout timeout);
  }

type 'err t = {
  scheduler : Scheduler.t;
  clock : clock;
  tracer : Capabilities.tracer option;
  sampler : Sampler.t;
  logger : Capabilities.logger option;
  meter : Capabilities.meter option;
  random : Capabilities.random;
  capture_backtrace : bool;
  mutable daemon_count : int;
  mutable daemon_waiters : (unit -> unit) list;
}

let create ?scheduler ?clock ?tracer ?(sampler = Sampler.always_on) ?logger ?meter
    ?random ?(capture_backtrace = false) () =
  let scheduler =
    match scheduler with
    | Some scheduler -> scheduler
    | None -> Scheduler.create ()
  in
  let clock =
    match clock with
    | Some clock -> clock
    | None -> default_clock ()
  in
  let random =
    match random with
    | Some random -> random
    | None -> Capabilities.random_default ()
  in
  {
    scheduler;
    clock;
    tracer;
    sampler;
    logger;
    meter;
    random;
    capture_backtrace;
    daemon_count = 0;
    daemon_waiters = [];
  }

let daemon_started runtime = runtime.daemon_count <- runtime.daemon_count + 1

let wake_daemon_waiters runtime =
  if runtime.daemon_count = 0 then begin
    let waiters = List.rev runtime.daemon_waiters in
    runtime.daemon_waiters <- [];
    List.iter
      (fun waiter -> Scheduler.enqueue runtime.scheduler waiter)
      waiters
  end

let daemon_finished runtime =
  if runtime.daemon_count <= 0 then
    invalid_arg "Eta_js.Runtime_core.daemon_finished: no active daemon";
  runtime.daemon_count <- runtime.daemon_count - 1;
  wake_daemon_waiters runtime

let daemon_failed runtime _cause =
  match runtime.logger with
  | None -> ()
  | Some logger ->
      logger#log
        {
          Capabilities.level = Error;
          body = "eta_js daemon failed";
          ts_ms = int_of_float (Js_interop.date_now ());
          attrs = [];
          trace_id = "";
          span_id = "";
        }

let drain_promise runtime =
  if runtime.daemon_count = 0 then Js.Promise.resolve ()
  else
    Js.Promise.make (fun ~resolve ~reject:_ ->
        let resolve_unit : unit -> unit = Obj.magic resolve in
        runtime.daemon_waiters <-
          (fun () -> resolve_unit ()) :: runtime.daemon_waiters)
