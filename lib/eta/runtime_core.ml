module P_atomic = Portable.Atomic
module RObs = Runtime_observability
module Sch = Schedule

let option_map f = function None -> None | Some value -> Some (f value)

let eio_context_key : unit Eio.Fiber.key = Eio.Fiber.create_key ()

let has_eio_fiber_context () =
  try
    ignore (Eio.Fiber.get eio_context_key);
    true
  with Stdlib.Effect.Unhandled _ -> false

let cancel_protect f =
  if has_eio_fiber_context () then Eio.Cancel.protect f else f ()

(* Typed failures cross Eio fibers through OCaml exceptions. This is the only
   place that may pack/unpack a typed Cause through [Obj.t]. The fresh
   [Typed_fail] key is the dynamic proof that the unpacking interpreter is the
   one that packed the value; mismatched keys are treated as ordinary defects by
   [cause_of_exn]. Do not copy this erasure pattern into feature modules. *)
exception Raised_cause of int * Obj.t

module Typed_fail : sig
  type key

  val fresh : unit -> key
  val int : key -> int
end = struct
  type key = int
  let counter = Atomic.make 0
  let fresh () = Atomic.fetch_and_add counter 1 + 1
  let int key = key
end

let[@cold][@zero_alloc assume error] raise_cause key cause =
  raise (Raised_cause (Typed_fail.int key, Obj.repr cause))

let[@cold][@zero_alloc assume error] raise_fail key err = raise_cause key (Cause.Fail err)

let rec cause_of_exn ?backtrace ~capture_backtrace key exn =
  match exn with
  | Raised_cause (k, cause) when k = Typed_fail.int key -> Obj.obj cause
  | Eio.Cancel.Cancelled _ -> Cause.interrupt
  | Blocking_runtime.Callback_raised (exn, bt) ->
      RObs.die_of_exn ~backtrace:bt ~capture_backtrace exn
  (* Bare [Stdlib.Exit] is user code raising a normal OCaml exception. Eta
     cancellation must arrive as [Eio.Cancel.Cancelled _], including internal
     cancellations whose reason value happens to be [Exit]. *)
  | Fun.Finally_raised exn -> cause_of_exn ~capture_backtrace key exn
  | Eio.Exn.Multiple causes ->
      let causes =
        List.map
          (fun (exn, bt) ->
            cause_of_exn ~backtrace:bt ~capture_backtrace key exn)
          causes
      in
      (match causes with
      | [] -> failwith "Eio.Exn.Multiple: empty"
      | causes when List.for_all Cause.is_interrupt_only causes -> Cause.interrupt
      | [ cause ] -> cause
      | causes -> Cause.concurrent causes)
  | exn -> RObs.die_of_exn ?backtrace ~capture_backtrace exn

type 'err t = {
  sleep : Duration.t -> unit;
  now_ms : unit -> int;
  tracer : Capabilities.tracer;
  tracing_enabled : bool;
  sampler : Sampler.t;
  auto_instrument : bool;
  logger : Capabilities.logger;
  logging_enabled : bool;
  meter : Capabilities.meter;
  metrics_enabled : bool;
  random : Capabilities.random;
  island_pool : Island_runtime.pool option;
  blocking_pool : Blocking_runtime.t option;
  default_blocking_pool : Blocking_runtime.t Lazy.t;
  default_island_wait_pool : Blocking_runtime.t Lazy.t;
  substrate : Runtime_substrate.t;
  capture_backtrace : bool;
  outer_sw : Eio.Switch.t;
  active : int P_atomic.t;
  active_mutex : Eio.Mutex.t;
  active_condition : Eio.Condition.t;
  default_fail_key : Typed_fail.key;
}


let create ~sw ~clock ?sleep ?tracer ?(sampler = Sampler.always_on)
    ?(auto_instrument = false) ?logger ?meter ?random ?island_pool
    ?blocking_pool ?blocking_runner ?(substrate = Runtime_substrate.direct)
    ?(capture_backtrace = true) () =
  let clock = (clock :> float Eio.Time.clock_ty Eio.Std.r) in
  let tracing_enabled = Option.is_some tracer in
  let logging_enabled = Option.is_some logger in
  let metrics_enabled = Option.is_some meter in
  let tracer = Option.value tracer ~default:Tracer.noop in
  let logger = Option.value logger ~default:Logger.noop in
  let meter = Option.value meter ~default:Meter.noop in
  let sleep =
    match sleep with
    | Some sleep -> sleep
    | None ->
        fun d ->
          let secs = Duration.to_seconds_float d in
          if secs > 0.0 then Eio.Time.sleep clock secs
  in
  let now_ms () =
    let secs = Eio.Time.now clock in
    int_of_float (secs *. 1000.0)
  in
  let random =
    match random with
    | Some random -> random
    | None ->
        let seed =
          int_of_float (Eio.Time.now clock *. 1_000_000.0) land 0x3fffffff
        in
        Capabilities.random_of_seed seed
  in
  {
    sleep;
    now_ms;
    tracer;
    tracing_enabled;
    sampler;
    auto_instrument;
    logger;
    logging_enabled;
    meter;
    metrics_enabled;
    random;
    island_pool;
    blocking_pool;
    default_blocking_pool =
      lazy
        (match blocking_runner with
         | None ->
             Blocking_runtime.Pool.create ~name:"runtime.default"
               Blocking_runtime.default_config
         | Some runner ->
             Blocking_runtime.Pool.create ~name:"runtime.default" ~runner
               Blocking_runtime.default_config);
    default_island_wait_pool =
      lazy
        (let config =
           {
             Blocking_runtime.default_config with
             shutdown_policy = Blocking_runtime.Detach_started;
           }
         in
         match blocking_runner with
         | None -> Blocking_runtime.Pool.create ~name:"runtime.island_wait" config
         | Some runner ->
             Blocking_runtime.Pool.create ~name:"runtime.island_wait" ~runner
               config);
    substrate;
    capture_backtrace;
    outer_sw = sw;
    active = P_atomic.make 0;
    active_mutex = Eio.Mutex.create ();
    active_condition = Eio.Condition.create ();
    default_fail_key = Typed_fail.fresh ();
  }

let incr_active runtime =
  Eio.Mutex.use_rw ~protect:(has_eio_fiber_context ()) runtime.active_mutex
  @@ fun () -> P_atomic.incr runtime.active

let decr_active runtime =
  Eio.Mutex.use_rw ~protect:(has_eio_fiber_context ()) runtime.active_mutex
  @@ fun () ->
  P_atomic.decr runtime.active;
  Eio.Condition.broadcast runtime.active_condition

let wait_active_zero runtime =
  Eio.Mutex.use_rw ~protect:(has_eio_fiber_context ()) runtime.active_mutex
  @@ fun () ->
  while P_atomic.get runtime.active > 0 do
    Eio.Condition.await runtime.active_condition runtime.active_mutex
  done

let emit_daemon_failure runtime cause =
  RObs.emit_daemon_failure ~now_ms:runtime.now_ms
    ~logging_enabled:runtime.logging_enabled ~logger:runtime.logger
    ~tracing_enabled:runtime.tracing_enabled ~tracer:runtime.tracer cause

let cause_of_exn_runtime runtime key exn =
  cause_of_exn ~capture_backtrace:runtime.capture_backtrace key exn

let die_of_exn_runtime runtime exn =
  RObs.die_of_exn ~capture_backtrace:runtime.capture_backtrace exn

let island_pool runtime override =
  match override with
  | Some pool -> pool
  | None -> (
      match runtime.island_pool with
      | Some pool -> pool
      | None -> failwith "Effect.island: island executor not configured")

let blocking_pool runtime override =
  match override with
  | Some pool -> pool
  | None -> (
      match runtime.blocking_pool with
      | Some pool -> pool
      | None -> Lazy.force runtime.default_blocking_pool)

let emit_blocking_event runtime event =
  RObs.emit_blocking_event ~now_ms:runtime.now_ms
    ~tracing_enabled:runtime.tracing_enabled ~tracer:runtime.tracer
    ~metrics_enabled:runtime.metrics_enabled ~meter:runtime.meter event

let run_finalizers ~runtime ~fail_key finalizers =
  cancel_protect @@ fun () ->
  match !finalizers with
  | [] -> None
  | fs ->
      finalizers := [];
      fs
      |> List.filter_map (fun f ->
             try
               f ();
               None
             with exn -> Some (cause_of_exn_runtime runtime fail_key exn))
      |> (function
           | [] -> None
           | [ cause ] -> Some cause
           | causes -> Some (Cause.sequential causes))

let render_finalizer_cause ~error_renderer cause =
  Cause.finalizer_of_cause
    (fun err ->
      RObs.render_typed_failure ~error_renderer (Obj.repr err))
    cause

let with_finalizers ~runtime ~fail_key ~error_renderer finalizers body =
  match body () with
  | value -> (
      match run_finalizers ~runtime ~fail_key finalizers with
      | None -> value
      | Some finalizer ->
          raise_cause fail_key
            (Cause.finalizer (render_finalizer_cause ~error_renderer finalizer)))
  | exception (Eio.Cancel.Cancelled _ as exn) -> (
      match run_finalizers ~runtime ~fail_key finalizers with
      | None -> raise exn
      | Some finalizer ->
          raise_cause fail_key
            (Cause.suppressed ~primary:Cause.interrupt
               ~finalizer:(render_finalizer_cause ~error_renderer finalizer)))
  | exception exn ->
      let primary = cause_of_exn_runtime runtime fail_key exn in
      let cause =
        match run_finalizers ~runtime ~fail_key finalizers with
        | None -> primary
        | Some finalizer ->
            Cause.suppressed ~primary
              ~finalizer:(render_finalizer_cause ~error_renderer finalizer)
      in
      raise_cause fail_key cause
