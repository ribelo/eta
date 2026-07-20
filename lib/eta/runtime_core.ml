module P_atomic = Atomic
module RObs = Runtime_observability
module Sch = Schedule

(* Typed failures cross runtime fibers through OCaml exceptions. This is the only
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

let cancellation_reason contract exn =
  contract.Runtime_contract.cancellation_reason exn

let is_cancellation contract exn =
  Option.is_some (cancellation_reason contract exn)

let rec cause_of_exn ?backtrace ~contract ~capture_backtrace key exn =
  match exn with
  | Raised_cause (k, cause) when k = Typed_fail.int key -> Obj.obj cause
  (* Bare [Stdlib.Exit] is user code raising a normal OCaml exception. Eta
     cancellation must be recognized by the runtime contract, including
     internal cancellations whose reason value happens to be [Exit]. *)
  | Fun.Finally_raised exn ->
      cause_of_exn ~contract ~capture_backtrace key exn
  | exn -> (
      match cancellation_reason contract exn with
      | Some _ -> Cause.interrupt
      | None -> (
          match contract.Runtime_contract.multiple_exceptions exn with
          | Some causes ->
              let causes =
                List.map
                  (fun (exn, bt) ->
                    cause_of_exn ~contract ~backtrace:bt ~capture_backtrace key
                      exn)
                  causes
              in
              (match causes with
              | [] -> failwith "Runtime_contract.multiple_exceptions: empty"
              | causes when List.for_all Cause.is_interrupt_only causes ->
                  Cause.interrupt
              | [ cause ] -> cause
              | causes -> Cause.concurrent causes)
          | None -> RObs.die_of_exn contract ?backtrace ~capture_backtrace exn))

type drain_waiter = {
  drain_resolver : unit Runtime_contract.resolver;
  mutable drain_active : bool;
}

let clock_override : Capabilities.clock Runtime_contract.local =
  Runtime_contract.create_local ()

let random_override : Capabilities.random Runtime_contract.local =
  Runtime_contract.create_local ()

let logger_override : Capabilities.logger Runtime_contract.local =
  Runtime_contract.create_local ()

let tracer_override : Capabilities.tracer Runtime_contract.local =
  Runtime_contract.create_local ()

type 'err t = {
  clock : Capabilities.clock;
  capability_overrides_active : bool;
  tracer : Capabilities.tracer;
  tracing_enabled : bool;
  sampler : Sampler.t;
  auto_instrument : bool;
  logger : Capabilities.logger;
  logging_enabled : bool;
  observability_suppressed : bool;
  meter : Capabilities.meter;
  metrics_enabled : bool;
  random : Capabilities.random;
  services : (int, Runtime_contract.service) Hashtbl.t;
  services_lock : Sync_lock.t;
  contract : Runtime_contract.t;
  capture_backtrace : bool;
  outer_scope : Runtime_contract.scope;
  active : int P_atomic.t;
  active_lock : Sync_lock.t;
  active_waiters : drain_waiter list ref;
  default_fail_key : Typed_fail.key;
}

let create_with_contract ~contract ?sleep ?now_ms ?tracer
    ?(sampler = Sampler.always_on) ?(auto_instrument = false) ?logger ?meter
    ?random ?(services = []) ?(capture_backtrace = true) () =
  let tracing_enabled = Option.is_some tracer in
  let logging_enabled = Option.is_some logger in
  let metrics_enabled = Option.is_some meter in
  let tracer = Option.value tracer ~default:Tracer.noop in
  let logger = Option.value logger ~default:Logger.noop in
  let meter = Option.value meter ~default:Meter.noop in
  let sleep = Option.value sleep ~default:contract.Runtime_contract.sleep in
  let now_ms = Option.value now_ms ~default:contract.Runtime_contract.now_ms in
  let clock : Capabilities.clock =
    object
      method now_ms () = now_ms ()
      method sleep duration = sleep duration
    end
  in
  let contract =
    { contract with Runtime_contract.sleep = sleep; now_ms = now_ms }
  in
  let random =
    match random with
    | Some random -> random
    | None ->
        let seed = (now_ms () * 1_000) land 0x3fffffff in
        Capabilities.random_of_seed seed
  in
  let services_table = Hashtbl.create (List.length services) in
  List.iter
    (fun (Runtime_contract.Service (key, value)) ->
      Hashtbl.replace services_table
        (Runtime_contract.Backend.service_key_id key)
        (Runtime_contract.Service (key, value)))
    services;
  {
    clock;
    capability_overrides_active = false;
    tracer;
    tracing_enabled;
    sampler;
    auto_instrument;
    logger;
    logging_enabled;
    observability_suppressed = false;
    meter;
    metrics_enabled;
    random;
    services = services_table;
    services_lock = Sync_lock.create ();
    contract;
    capture_backtrace;
    outer_scope = contract.Runtime_contract.root_scope;
    active = P_atomic.make 0;
    active_lock = Sync_lock.create ();
    active_waiters = ref [];
    default_fail_key = Typed_fail.fresh ();
  }

let local_override runtime key =
  runtime.contract.Runtime_contract.local_get key

let current_clock runtime =
  if not runtime.capability_overrides_active then runtime.clock
  else Option.value (local_override runtime clock_override) ~default:runtime.clock

let current_random runtime =
  if not runtime.capability_overrides_active then runtime.random
  else Option.value (local_override runtime random_override) ~default:runtime.random

let current_logger runtime =
  let override =
    if runtime.capability_overrides_active then
      local_override runtime logger_override
    else None
  in
  ( (not runtime.observability_suppressed)
    && (runtime.logging_enabled || Option.is_some override),
    Option.value override ~default:runtime.logger )

let current_tracer runtime =
  let override =
    if runtime.capability_overrides_active then
      local_override runtime tracer_override
    else None
  in
  ( (not runtime.observability_suppressed)
    && (runtime.tracing_enabled || Option.is_some override),
    Option.value override ~default:runtime.tracer )

let resolve_drain_waiters runtime waiters =
  List.iter
    (fun waiter ->
      if waiter.drain_active then (
        waiter.drain_active <- false;
        runtime.contract.Runtime_contract.resolve_promise waiter.drain_resolver
          ()))
    waiters

let incr_active runtime =
  Sync_lock.use runtime.active_lock @@ fun () -> P_atomic.incr runtime.active

let decr_active runtime =
  let waiters =
    Sync_lock.use runtime.active_lock @@ fun () ->
    P_atomic.decr runtime.active;
    if P_atomic.get runtime.active = 0 then (
      let waiters = !(runtime.active_waiters) in
      runtime.active_waiters := [];
      waiters)
    else []
  in
  resolve_drain_waiters runtime waiters

let wait_active_zero runtime =
  let rec loop () =
    match
      Sync_lock.use runtime.active_lock @@ fun () ->
      if P_atomic.get runtime.active = 0 then None
      else
        let promise, resolver =
          runtime.contract.Runtime_contract.create_promise ()
        in
        let waiter = { drain_resolver = resolver; drain_active = true } in
        runtime.active_waiters := waiter :: !(runtime.active_waiters);
        Some (promise, waiter)
    with
    | None -> ()
    | Some (promise, waiter) -> (
        try
          runtime.contract.Runtime_contract.await_promise promise;
          loop ()
        with exn
          when Option.is_some
                 (runtime.contract.Runtime_contract.cancellation_reason exn) ->
          runtime.contract.Runtime_contract.protect (fun () ->
              Sync_lock.use runtime.active_lock @@ fun () ->
              waiter.drain_active <- false);
          raise exn)
  in
  loop ()

let emit_daemon_failure runtime cause =
  let clock = current_clock runtime in
  let logging_enabled, logger = current_logger runtime in
  let tracing_enabled, tracer = current_tracer runtime in
  RObs.emit_daemon_failure ~contract:runtime.contract
    ~now_ms:(fun () -> clock#now_ms ()) ~logging_enabled ~logger
    ~tracing_enabled ~tracer cause

let cause_of_exn_runtime ?backtrace runtime key exn =
  cause_of_exn ?backtrace ~contract:runtime.contract
    ~capture_backtrace:runtime.capture_backtrace key exn

let die_of_exn_runtime runtime exn =
  RObs.die_of_exn runtime.contract
    ~capture_backtrace:runtime.capture_backtrace exn

let service runtime key =
  Sync_lock.use runtime.services_lock @@ fun () ->
  match
    Hashtbl.find_opt runtime.services
      (Runtime_contract.Backend.service_key_id key)
  with
  | None -> None
  | Some service -> Runtime_contract.Backend.service_value key service

let run_finalizers ~runtime ~fail_key finalizers =
  match !finalizers with
  | [] -> None
  | fs ->
      (* [protect] prevents cancellation while finalizers run. When there are no
         finalizers (the common path for pure effects), skip it entirely — this
         avoids the cancel-context [Hashtbl] iteration that [protect] performs on
         every call, which is a top hotspot under per-request effect dispatch. *)
      runtime.contract.Runtime_contract.protect @@ fun () ->
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

let with_finalizers ?(interrupt_of_cancel = fun _ -> Cause.interrupt) ~runtime
    ~fail_key ~error_renderer finalizers body =
  match body () with
  | value -> (
      match run_finalizers ~runtime ~fail_key finalizers with
      | None -> value
      | Some finalizer ->
          raise_cause fail_key
            (Cause.finalizer (render_finalizer_cause ~error_renderer finalizer)))
  | exception exn when is_cancellation runtime.contract exn -> (
      let reason =
        match cancellation_reason runtime.contract exn with
        | Some reason -> reason
        | None -> assert false
      in
      match run_finalizers ~runtime ~fail_key finalizers with
      | None -> raise exn
      | Some finalizer ->
          raise_cause fail_key
            (Cause.suppressed ~primary:(interrupt_of_cancel reason)
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
