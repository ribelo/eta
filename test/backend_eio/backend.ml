type ctx = Eio.Switch.t
type clock = Eta_test.Test_clock.t
type 'a promise = 'a Eio.Promise.t
type 'a resolver = 'a Eio.Promise.u
type 'a stream = 'a Eio.Stream.t
type 'a cancelable = {
  cancelable_promise : [ `Returned of 'a | `Cancelled ] Eio.Promise.t;
  cancelable_cancel : (unit -> unit) option ref;
}

let name = "eio"

let reclaim_eio_backend () =
  Gc.full_major ();
  Gc.compact ()

let run_linux_eio ?fallback f =
  reclaim_eio_backend ();
  Fun.protect ~finally:reclaim_eio_backend (fun () ->
      Eio_linux.run ?fallback ~queue_depth:64 ~n_blocks:1 f)

let run_eio f =
  match Sys.getenv_opt "EIO_BACKEND" with
  | Some ("linux" | "io-uring") -> run_linux_eio f
  | None | Some "" ->
      run_linux_eio ~fallback:(fun _ -> Eio_main.run f) f
  | _ -> Eio_main.run f

let create_deterministic_runtime ?tracer ?sampler ?auto_instrument ?logger
    ?meter ?random ?capture_backtrace stdenv sw =
  let clock = Eta_test.Test_clock.create () in
  let sleep duration =
    Eta_test.Test_clock.adjust clock duration;
    Eio.Fiber.yield ()
  in
  Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~sleep
    ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
    ?tracer ?sampler ?auto_instrument ?logger ?meter ?random ?capture_backtrace
    ()

let with_runtime f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = create_deterministic_runtime stdenv sw in
  f sw rt

let with_runtime_contract f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let contract =
    Eta.Runtime_contract.of_runtime
      (Eta_eio.runtime ~sw ~clock:(Eio.Stdenv.clock stdenv))
  in
  f sw contract

let with_traced_runtime f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    create_deterministic_runtime ~tracer:(Eta.Tracer.as_capability tracer)
      stdenv sw
  in
  f sw rt tracer

let with_custom_tracer_runtime tracer f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = create_deterministic_runtime ~tracer stdenv sw in
  f sw rt

let with_sampled_traced_runtime sampler f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    create_deterministic_runtime ~tracer:(Eta.Tracer.as_capability tracer)
      ~sampler stdenv sw
  in
  f sw rt tracer

let with_seeded_sampled_traced_runtime ~seed sampler f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    create_deterministic_runtime ~tracer:(Eta.Tracer.as_capability tracer)
      ~sampler ~random:(Eta.Capabilities.random_of_seed seed) stdenv sw
  in
  f sw rt tracer

let with_auto_traced_runtime auto_instrument f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    create_deterministic_runtime ~tracer:(Eta.Tracer.as_capability tracer)
      ~auto_instrument stdenv sw
  in
  f sw rt tracer

let with_meter_runtime f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let meter = Eta.Meter.in_memory () in
  let rt =
    create_deterministic_runtime ~meter:(Eta.Meter.as_capability meter) stdenv
      sw
  in
  f sw rt meter

let with_meter_test_clock f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let meter = Eta.Meter.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ~meter:(Eta.Meter.as_capability meter) ()
  in
  f sw clock rt meter

let with_logger_runtime f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let logger = Eta.Logger.in_memory () in
  let rt =
    create_deterministic_runtime ~logger:(Eta.Logger.as_capability logger)
      stdenv sw
  in
  f sw rt logger

let with_observed_runtime f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Eta.Tracer.in_memory () in
  let logger = Eta.Logger.in_memory () in
  let meter = Eta.Meter.in_memory () in
  let rt =
    create_deterministic_runtime ~tracer:(Eta.Tracer.as_capability tracer)
      ~logger:(Eta.Logger.as_capability logger)
      ~meter:(Eta.Meter.as_capability meter) stdenv sw
  in
  f sw rt tracer logger meter

let with_runtime_capture_backtrace capture_backtrace f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = create_deterministic_runtime ~capture_backtrace stdenv sw in
  f sw rt

let with_test_clock f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  f sw clock rt

let with_traced_test_clock f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  f sw clock rt tracer

let with_seeded_test_clock ~seed f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ~random:(Eta.Capabilities.random_of_seed seed)
      ()
  in
  f sw clock rt

let with_seeded_logged_test_clock ~seed f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let sleeps = ref [] in
  let sleep duration =
    sleeps := duration :: !sleeps;
    Eta_test.Test_clock.sleep clock duration
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~sleep
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ~random:(Eta.Capabilities.random_of_seed seed)
      ()
  in
  f sw clock rt sleeps

let run rt eff = Eta_eio.Runtime.run rt eff
let run_exn rt eff = Eta_eio.Runtime.run_exn rt eff
let drain = Eta_eio.Runtime.drain

let fork_run sw rt eff =
  let promise, resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolver (run rt eff));
  promise

let cancelable_effect cancel_ref eff =
  Eta.Effect.Expert.make ~capabilities:[ `Concurrency ]
    ~leaf_name:"test.cancelable" @@ fun context ->
  let contract = Eta.Effect.Expert.contract context in
  contract.Eta.Runtime_contract.cancel_sub @@ fun cancel_context ->
  cancel_ref :=
    Some (fun () -> contract.Eta.Runtime_contract.cancel cancel_context Exit);
  Eta.Effect.Expert.eval context eff

let fork_run_cancelable sw rt eff =
  let cancelable_cancel = ref None in
  let wrapped = cancelable_effect cancelable_cancel eff in
  let cancelable_promise, resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve resolver
        (try `Returned (run rt wrapped) with
        | Eio.Cancel.Cancelled _ -> `Cancelled));
  { cancelable_promise; cancelable_cancel }

let cancel_fiber cancelable =
  match !(cancelable.cancelable_cancel) with
  | Some cancel -> cancel ()
  | None -> invalid_arg "Eio backend cancelable fiber has not started"

let await_cancelable cancelable = Eio.Promise.await cancelable.cancelable_promise

let await = Eio.Promise.await
let is_resolved = Eio.Promise.is_resolved
let yield = Eio.Fiber.yield
let yield_effect () = Eta.Effect.sync Eio.Fiber.yield

let create_promise () = Eio.Promise.create ()
let resolve = Eio.Promise.resolve
let try_resolve resolver value = ignore (Eio.Promise.try_resolve resolver value)
let await_effect promise = Eta.Effect.sync (fun () -> Eio.Promise.await promise)
let await_cancel_effect () = Eta.Effect.sync Eio.Fiber.await_cancel

let create_stream = Eio.Stream.create
let stream_add = Eio.Stream.add
let stream_take = Eio.Stream.take

let adjust_clock = Eta_test.Test_clock.adjust
let set_clock = Eta_test.Test_clock.set_time
let sleeper_count = Eta_test.Test_clock.sleeper_count
