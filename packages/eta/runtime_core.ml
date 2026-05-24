module EV = Effect_ast
module P_atomic = Portable.Atomic
module RObs = Runtime_observability
module Sch = Schedule

let option_map f = function None -> None | Some value -> Some (f value)

(* Typed failures cross Eio fibers through OCaml exceptions. The [Obj.t] payload
   is private to this module and is unpacked only after the fresh [Typed_fail]
   key matches the interpreter frame that packed it. *)
exception Raised_cause of int * Obj.t
exception Timeout_as_fired of int

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

let raise_cause key cause =
  raise (Raised_cause (Typed_fail.int key, Obj.repr cause))

let raise_fail key err = raise_cause key (Cause.Fail err)

let rec cause_of_exn ?backtrace ~capture_backtrace key exn =
  match exn with
  | Raised_cause (k, cause) when k = Typed_fail.int key -> Obj.obj cause
  | Eio.Cancel.Cancelled _ -> Cause.interrupt
  | Exit -> Cause.interrupt
  | Fun.Finally_raised exn -> cause_of_exn ~capture_backtrace key exn
  | Eio.Exn.Multiple causes ->
      let causes =
        List.map
          (fun (exn, bt) ->
            cause_of_exn ~backtrace:bt ~capture_backtrace key exn)
          causes
      in
      if List.for_all Cause.is_interrupt_only causes then Cause.interrupt
      else Cause.concurrent causes
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
  capture_backtrace : bool;
  outer_sw : Eio.Switch.t;
  active : int P_atomic.t;
  default_fail_key : Typed_fail.key;
}


let create ~sw ~clock ?sleep ?tracer ?(sampler = Sampler.always_on)
    ?(auto_instrument = false) ?logger ?meter ?random ?island_pool
    ?blocking_pool ?(capture_backtrace = true) () =
  let clock = (clock :> float Eio.Time.clock_ty Eio.Std.r) in
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
    tracing_enabled = tracer != Tracer.noop;
    sampler;
    auto_instrument;
    logger;
    logging_enabled = logger != Logger.noop;
    meter;
    metrics_enabled = meter != Meter.noop;
    random;
    island_pool;
    blocking_pool;
    default_blocking_pool =
      lazy
        (Blocking_runtime.Pool.create ~name:"runtime.default"
           Blocking_runtime.default_config);
    capture_backtrace;
    outer_sw = sw;
    active = P_atomic.make 0;
    default_fail_key = Typed_fail.fresh ();
  }

let emit_daemon_failure runtime cause =
  RObs.emit_daemon_failure ~now_ms:runtime.now_ms
    ~logging_enabled:runtime.logging_enabled ~logger:runtime.logger
    ~tracing_enabled:runtime.tracing_enabled ~tracer:runtime.tracer cause

let cause_of_exn_runtime runtime key exn =
  cause_of_exn ~capture_backtrace:runtime.capture_backtrace key exn

let die_of_exn_runtime runtime exn =
  RObs.die_of_exn ~capture_backtrace:runtime.capture_backtrace exn

let rec has_timeout_as token = function
  | Timeout_as_fired observed -> observed = token
  | Fun.Finally_raised exn -> has_timeout_as token exn
  | Eio.Exn.Multiple causes ->
      List.exists (fun (exn, _) -> has_timeout_as token exn) causes
  | _ -> false

let rec only_timeout_as_or_interrupt token = function
  | Timeout_as_fired observed -> observed = token
  | Eio.Cancel.Cancelled _ | Exit -> true
  | Raised_cause (_, cause) -> (
      let rec only_fail_or_interrupt : _ Cause.t -> bool = function
        | Cause.Fail _ | Cause.Interrupt _ -> true
        | Cause.Sequential causes | Cause.Concurrent causes ->
            List.for_all only_fail_or_interrupt causes
        | Cause.Suppressed _ | Cause.Die _ -> false
      in
      match Obj.obj cause with
      | cause when only_fail_or_interrupt cause -> true
      | cause -> Cause.is_interrupt_only cause)
  | Fun.Finally_raised exn -> only_timeout_as_or_interrupt token exn
  | Eio.Exn.Multiple causes ->
      List.for_all
        (fun (exn, _) -> only_timeout_as_or_interrupt token exn)
        causes
  | _ -> false

let cause_of_timeout_as_exn runtime fail_key token on_timeout exn =
  let rec convert ?backtrace = function
    | Timeout_as_fired observed when observed = token -> Cause.Fail on_timeout
    | Fun.Finally_raised exn -> convert ?backtrace exn
    | Eio.Exn.Multiple causes ->
        causes
        |> List.map (fun (exn, bt) -> convert ~backtrace:bt exn)
        |> Cause.concurrent
    | exn ->
        cause_of_exn ?backtrace ~capture_backtrace:runtime.capture_backtrace
          fail_key exn
  in
  convert exn

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
  Eio.Cancel.protect @@ fun () ->
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

let with_finalizers ~runtime ~fail_key finalizers body =
  match body () with
  | value -> (
      match run_finalizers ~runtime ~fail_key finalizers with
      | None -> value
      | Some finalizer -> raise_cause fail_key finalizer)
  | exception exn ->
      let primary = cause_of_exn_runtime runtime fail_key exn in
      let cause =
        match run_finalizers ~runtime ~fail_key finalizers with
        | None -> primary
        | Some finalizer -> Cause.suppressed ~primary ~finalizer
      in
      raise_cause fail_key cause
