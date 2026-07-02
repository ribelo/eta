open Effect.Deep
module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe

module Runtime_contract = Eta.Runtime_contract

exception Cancelled of exn
exception Multiple of (exn * Printexc.raw_backtrace) list

let next_id = Atomic.make 0
let fresh_id () = Atomic.fetch_and_add next_id 1 + 1

module Js_host = struct
  let set_timeout_ = Unsafe.js_expr "setTimeout"
  let clear_timeout_ = Unsafe.js_expr "clearTimeout"
  let performance_now_ =
    Unsafe.js_expr "(function () { return performance.now(); })"

  let set_timeout ~ms f =
    (Unsafe.fun_call set_timeout_
       [| Unsafe.inject (Js.wrap_callback f); Unsafe.inject (Js.number_of_float ms) |]
      : Unsafe.any)

  let clear_timeout timeout_id =
    ignore (Unsafe.fun_call clear_timeout_ [| timeout_id |])

  let now_ms () =
    int_of_float
      (Js.to_float (Unsafe.fun_call performance_now_ [||] : Js.number_t))

  let post_task : (unit -> unit) -> unit =
    if
      Js.to_bool
        (Unsafe.js_expr "typeof queueMicrotask === 'function'" : bool Js.t)
    then
      let queue_microtask = Unsafe.js_expr "queueMicrotask" in
      fun f ->
        ignore
          (Unsafe.fun_call queue_microtask
             [| Unsafe.inject (Js.wrap_callback f) |])
    else
      fun f -> ignore (set_timeout ~ms:0.0 f)
end

let schedule = Js_host.post_task

type cancel_waiter = {
  mutable cancel_waiter_active : bool;
  cancel_waiter_wake : exn -> unit;
}

type cancel_context = {
  cancel_id : int;
  mutable cancel_reason : exn option;
  mutable cancel_waiters : cancel_waiter list;
  mutable cancel_children : cancel_context list;
}

type local_context =
  (int, Runtime_contract.local_binding list) Hashtbl.t

type scope = {
  scope_id : int;
  scope_name : string option;
  scope_cancel : cancel_context;
  mutable scope_children : unit promise list;
  mutable scope_failures : (exn * Printexc.raw_backtrace) list;
  mutable scope_failure : (exn * Printexc.raw_backtrace) option;
}

and fiber = {
  fiber_id : int;
  mutable fiber_scope : scope;
  mutable fiber_cancel : cancel_context;
  mutable fiber_locals : local_context;
  mutable fiber_protect_depth : int;
}

and 'a promise_state =
  | Pending of (('a, exn) result -> unit) list
  | Settled of ('a, exn) result

and 'a promise = {
  mutable state : 'a promise_state;
}

type 'a resolver = 'a promise

type 'a stream_putter = {
  put_value : 'a;
  put_resolver : unit resolver;
  mutable put_active : bool;
}

type 'a stream_taker = {
  take_resolver : 'a resolver;
  mutable take_active : bool;
}

type 'a stream = {
  stream_capacity : int;
  stream_values : 'a Queue.t;
  stream_putters : 'a stream_putter Queue.t;
  stream_takers : 'a stream_taker Queue.t;
}

type _ Effect.t += Await : 'a promise * (unit -> unit) option -> 'a Effect.t

let current_fiber : fiber option ref = ref None

let current () =
  match !current_fiber with
  | Some fiber -> fiber
  | None -> invalid_arg "Eta_jsoo: runtime operation outside an Eta_jsoo fiber"

let with_current fiber f =
  let previous = !current_fiber in
  current_fiber := Some fiber;
  Fun.protect ~finally:(fun () -> current_fiber := previous) f

let create_cancel_context () =
  {
    cancel_id = fresh_id ();
    cancel_reason = None;
    cancel_waiters = [];
    cancel_children = [];
  }

let rec cancel_context context reason =
  match context.cancel_reason with
  | Some _ -> ()
  | None ->
      context.cancel_reason <- Some reason;
      let waiters = context.cancel_waiters in
      context.cancel_waiters <- [];
      List.iter
        (fun waiter ->
          if waiter.cancel_waiter_active then (
            waiter.cancel_waiter_active <- false;
            waiter.cancel_waiter_wake reason))
        waiters;
      List.iter (fun child -> cancel_context child reason) context.cancel_children

let add_cancel_child ?(propagate = true) parent child =
  match parent.cancel_reason with
  | None -> parent.cancel_children <- child :: parent.cancel_children
  | Some reason ->
      if propagate then cancel_context child reason
      else parent.cancel_children <- child :: parent.cancel_children

let remove_cancel_child parent child =
  parent.cancel_children <-
    List.filter (fun candidate -> candidate.cancel_id <> child.cancel_id)
      parent.cancel_children

let check_cancel fiber =
  match (fiber.fiber_cancel.cancel_reason, fiber.fiber_protect_depth) with
  | Some reason, 0 -> raise (Cancelled reason)
  | _ -> ()

let add_cancel_waiter context wake =
  let waiter = { cancel_waiter_active = true; cancel_waiter_wake = wake } in
  match context.cancel_reason with
  | Some reason ->
      waiter.cancel_waiter_active <- false;
      wake reason;
      fun () -> ()
  | None ->
      context.cancel_waiters <- waiter :: context.cancel_waiters;
      fun () -> waiter.cancel_waiter_active <- false

let copy_locals locals =
  let copy = Hashtbl.create (Hashtbl.length locals) in
  Hashtbl.iter (fun key value -> Hashtbl.replace copy key value) locals;
  copy

let subscribe promise callback =
  match promise.state with
  | Pending callbacks -> promise.state <- Pending (callback :: callbacks)
  | Settled result -> schedule (fun () -> callback result)

let settle_once promise result =
  match promise.state with
  | Settled _ -> invalid_arg "Eta_jsoo.Promise.resolve: already resolved"
  | Pending callbacks ->
      promise.state <- Settled result;
      List.iter
        (fun callback -> schedule (fun () -> callback result))
        (List.rev callbacks)

let resolve_once promise value = settle_once promise (Ok value)
let reject_once promise exn = settle_once promise (Error exn)

let create_promise () =
  let cell = { state = Pending [] } in
  (cell, cell)

let run_continuation fiber continue =
  schedule (fun () -> with_current fiber continue)

let handle_effect fiber =
  let handler : type a. a Effect.t -> ((a, unit) continuation -> unit) option =
   fun eff ->
    match eff with
    | Await (promise, on_cancel) ->
        Some
          (fun continuation ->
            let resumed = ref false in
            let cancel_cleanup = ref (fun () -> ()) in
            let resume run =
              if not !resumed then (
                resumed := true;
                !cancel_cleanup ();
                run_continuation fiber run)
            in
            if fiber.fiber_protect_depth = 0 then
              cancel_cleanup :=
                add_cancel_waiter fiber.fiber_cancel (fun reason ->
                    Option.iter (fun hook -> hook ()) on_cancel;
                    resume (fun () -> discontinue continuation (Cancelled reason)));
            subscribe promise (function
              | Ok value -> resume (fun () -> continue continuation value)
              | Error exn -> resume (fun () -> discontinue continuation exn)))
    | _ -> None
  in
  handler

let run_handled fiber thunk finish =
  with_current fiber @@ fun () ->
  let handler : (_, unit) Effect.Deep.handler =
    {
      retc = (fun value -> finish (Ok value));
      exnc =
        (fun exn ->
          let bt = Printexc.get_raw_backtrace () in
          finish (Error (exn, bt)));
      effc =
        (fun (type a) (eff : a Effect.t) ->
          (handle_effect fiber eff
            : ((a, unit) continuation -> unit) option));
    }
  in
  match_with thunk () handler

let await ?on_cancel promise =
  let fiber = current () in
  check_cancel fiber;
  Effect.perform (Await (promise, on_cancel))

let await_promise promise = await promise

let protect_impl ~check_after f =
  match !current_fiber with
  | None -> f ()
  | Some fiber ->
      fiber.fiber_protect_depth <- fiber.fiber_protect_depth + 1;
      match f () with
      | value ->
          fiber.fiber_protect_depth <- fiber.fiber_protect_depth - 1;
          if check_after then check_cancel fiber;
          value
      | exception exn ->
          fiber.fiber_protect_depth <- fiber.fiber_protect_depth - 1;
          raise exn

let protect f = protect_impl ~check_after:true f
let protect_without_check f = protect_impl ~check_after:false f

let new_scope ?name parent_cancel =
  let cancel = create_cancel_context () in
  let propagate =
    match !current_fiber with
    | None -> true
    | Some fiber -> fiber.fiber_protect_depth = 0
  in
  add_cancel_child ~propagate parent_cancel cancel;
  {
    scope_id = fresh_id ();
    scope_name = name;
    scope_cancel = cancel;
    scope_children = [];
    scope_failures = [];
    scope_failure = None;
  }

let root_scope =
  let cancel = create_cancel_context () in
  {
    scope_id = fresh_id ();
    scope_name = Some "eta_jsoo.root";
    scope_cancel = cancel;
    scope_children = [];
    scope_failures = [];
    scope_failure = None;
  }

let record_scope_failure scope exn bt =
  scope.scope_failures <- (exn, bt) :: scope.scope_failures

let fail_scope ?bt scope exn =
  let bt = Option.value bt ~default:(Printexc.get_raw_backtrace ()) in
  if Option.is_none scope.scope_failure then
    scope.scope_failure <- Some (exn, bt);
  cancel_context scope.scope_cancel exn

let raise_scope_failures = function
  | [] -> invalid_arg "Eta_jsoo.run_scope: empty failure list"
  | [ exn, bt ] -> Printexc.raise_with_backtrace exn bt
  | failures -> raise (Multiple failures)

let raise_scope_cancellation scope =
  match scope.scope_failure with
  | Some (exn, bt) -> Printexc.raise_with_backtrace exn bt
  | None -> (
      match scope.scope_cancel.cancel_reason with
      | Some reason -> raise (Cancelled reason)
      | None -> raise (Cancelled Exit))

let spawn_fiber ?(daemon = false) ~scope ~locals body =
  let fiber =
    {
      fiber_id = fresh_id ();
      fiber_scope = scope;
      fiber_cancel = scope.scope_cancel;
      fiber_locals = locals;
      fiber_protect_depth = 0;
    }
  in
  let promise, resolver = create_promise () in
  let finish = function
    | Ok _ -> resolve_once resolver ()
    | Error (Cancelled _, _) -> resolve_once resolver ()
    | Error (exn, bt) ->
        if not daemon then (
          record_scope_failure scope exn bt;
          cancel_context scope.scope_cancel exn);
        resolve_once resolver ()
  in
  if not daemon then scope.scope_children <- promise :: scope.scope_children;
  schedule (fun () -> run_handled fiber body finish);
  promise

let fork scope body =
  let parent = current () in
  ignore
    (spawn_fiber ~scope ~locals:(copy_locals parent.fiber_locals) body
      : unit promise)

let fork_daemon scope body =
  let parent = current () in
  ignore
    (spawn_fiber ~daemon:true ~scope ~locals:(copy_locals parent.fiber_locals)
       (fun () -> ignore (body ()))
      : unit promise)

let await_children scope =
  let children = List.rev scope.scope_children in
  scope.scope_children <- [];
  List.iter await_promise children

let run_scope ?name body =
  let fiber = current () in
  let child_scope = new_scope ?name fiber.fiber_cancel in
  let previous_scope = fiber.fiber_scope in
  let previous_cancel = fiber.fiber_cancel in
  fiber.fiber_scope <- child_scope;
  fiber.fiber_cancel <- child_scope.scope_cancel;
  let body_result =
    try Ok (body child_scope) with
    | Cancelled _ as exn -> Error (exn, Printexc.get_raw_backtrace ())
    | exn ->
        let bt = Printexc.get_raw_backtrace () in
        record_scope_failure child_scope exn bt;
        cancel_context child_scope.scope_cancel exn;
        Error (exn, bt)
  in
  protect_without_check (fun () -> await_children child_scope);
  remove_cancel_child previous_cancel child_scope.scope_cancel;
  fiber.fiber_scope <- previous_scope;
  fiber.fiber_cancel <- previous_cancel;
  match (body_result, List.rev child_scope.scope_failures) with
  | Ok value, [] -> (
      match child_scope.scope_cancel.cancel_reason with
      | None ->
          check_cancel fiber;
          value
      | Some _ -> raise_scope_cancellation child_scope)
  | Ok _, failures -> raise_scope_failures failures
  | Error (Cancelled _, _), [] -> raise_scope_cancellation child_scope
  | Error (exn, bt), [] -> Printexc.raise_with_backtrace exn bt
  | Error _, failures -> raise_scope_failures failures

let sleep duration =
  let seconds = Eta.Duration.to_seconds_float duration in
  if seconds > 0.0 then (
    let promise, resolver = create_promise () in
    let timeout_id =
      Js_host.set_timeout ~ms:(seconds *. 1000.0) (fun () ->
          match promise.state with
          | Settled _ -> ()
          | Pending _ -> resolve_once resolver ())
    in
    await ~on_cancel:(fun () -> Js_host.clear_timeout timeout_id) promise)

let yield () =
  let promise, resolver = create_promise () in
  schedule (fun () -> resolve_once resolver ());
  await_promise promise
let check () = check_cancel (current ())
let await_cancel () =
  let fiber = current () in
  let promise, resolver = create_promise () in
  let cleanup =
    add_cancel_waiter fiber.fiber_cancel (fun reason -> resolve_once resolver reason)
  in
  let reason = await ~on_cancel:cleanup promise in
  raise (Cancelled reason)

let cancel_sub f =
  let fiber = current () in
  let parent = fiber.fiber_cancel in
  let child = create_cancel_context () in
  add_cancel_child ~propagate:(fiber.fiber_protect_depth = 0) parent child;
  fiber.fiber_cancel <- child;
  Fun.protect
    ~finally:(fun () ->
      fiber.fiber_cancel <- parent;
      remove_cancel_child parent child)
    (fun () -> f child)

let cancel = cancel_context

let cancellation_reason = function
  | Cancelled reason -> Some reason
  | _ -> None

let multiple_exceptions = function
  | Multiple failures -> Some failures
  | _ -> None

let local_get local =
  let fiber = current () in
  let id = Runtime_contract.Backend.local_id local in
  match Hashtbl.find_opt fiber.fiber_locals id with
  | None -> None
  | Some bindings ->
      List.find_map (Runtime_contract.Backend.local_binding_value local) bindings

let local_with_binding local value f =
  let fiber = current () in
  let id = Runtime_contract.Backend.local_id local in
  let previous = fiber.fiber_locals in
  let context = copy_locals previous in
  let stack = Option.value (Hashtbl.find_opt context id) ~default:[] in
  Hashtbl.replace context id (Runtime_contract.Local_binding (local, value) :: stack);
  fiber.fiber_locals <- context;
  Fun.protect ~finally:(fun () -> fiber.fiber_locals <- previous) f

module Worker_context = struct
  let run f = f ()
  let active () = false
end

let rec stream_take_active q =
  if Queue.is_empty q then None
  else
    let value = Queue.take q in
    if value.take_active then Some value else stream_take_active q

let rec stream_put_active q =
  if Queue.is_empty q then None
  else
    let value = Queue.take q in
    if value.put_active then Some value else stream_put_active q

let rec stream_pump stream =
  match stream_take_active stream.stream_takers with
  | Some taker when not (Queue.is_empty stream.stream_values) ->
      let value = Queue.take stream.stream_values in
      taker.take_active <- false;
      resolve_once taker.take_resolver value;
      stream_pump stream
  | Some taker -> (
      match stream_put_active stream.stream_putters with
      | None -> Queue.push taker stream.stream_takers
      | Some putter ->
          taker.take_active <- false;
          putter.put_active <- false;
          resolve_once taker.take_resolver putter.put_value;
          resolve_once putter.put_resolver ();
          stream_pump stream)
  | None ->
      while
        Queue.length stream.stream_values < stream.stream_capacity
        && not (Queue.is_empty stream.stream_putters)
      do
        match stream_put_active stream.stream_putters with
        | None -> ()
        | Some putter ->
            putter.put_active <- false;
            Queue.push putter.put_value stream.stream_values;
            resolve_once putter.put_resolver ()
      done

let create_stream capacity =
  if capacity <= 0 then
    invalid_arg "Eta_jsoo.Stream.create: capacity must be > 0";
  {
    stream_capacity = capacity;
    stream_values = Queue.create ();
    stream_putters = Queue.create ();
    stream_takers = Queue.create ();
  }

let stream_add stream value =
  stream_pump stream;
  if Queue.length stream.stream_values < stream.stream_capacity then (
    Queue.push value stream.stream_values;
    stream_pump stream)
  else
    let promise, resolver = create_promise () in
    let putter = { put_value = value; put_resolver = resolver; put_active = true } in
    Queue.push putter stream.stream_putters;
    protect (fun () -> await_promise promise)

let stream_take stream =
  stream_pump stream;
  match Queue.take_opt stream.stream_values with
  | Some value ->
      stream_pump stream;
      value
  | None ->
      let promise, resolver = create_promise () in
      let taker = { take_resolver = resolver; take_active = true } in
      Queue.push taker stream.stream_takers;
      await_promise promise

let stream_take_nonblocking stream =
  stream_pump stream;
  match Queue.take_opt stream.stream_values with
  | None -> None
  | Some value ->
      stream_pump stream;
      Some value

let now_ms = Js_host.now_ms

let clock : Eta.Capabilities.clock =
  object
    method sleep duration = sleep duration
  end

module Private = struct
  type nonrec 'a promise = 'a promise
  type nonrec 'a resolver = 'a resolver

  let create_promise = create_promise
  let resolve = resolve_once
  let reject = reject_once
  let await = await
end

let runtime () =
  (module struct
    type nonrec scope = scope
    type nonrec cancel_context = cancel_context
    type nonrec 'a promise = 'a promise
    type nonrec 'a resolver = 'a resolver
    type nonrec 'a stream = 'a stream

    let root_scope = root_scope
    let now_ms = now_ms
    let sleep = sleep
    let protect = protect
    let run_scope = run_scope
    let fail_scope = fail_scope
    let fork = fork
    let fork_daemon = fork_daemon
    let await_cancel = await_cancel
    let yield = yield
    let check = check
    let create_promise = create_promise
    let resolve_promise = resolve_once
    let await_promise = await_promise
    let create_stream = create_stream
    let stream_add = stream_add
    let stream_take = stream_take
    let stream_take_nonblocking = stream_take_nonblocking
    let with_worker_context = Worker_context.run
    let in_worker_context = Worker_context.active
    let cancellation_reason = cancellation_reason
    let multiple_exceptions = multiple_exceptions
    let cancel_sub = cancel_sub
    let cancel = cancel
    let local_get = local_get
    let local_with_binding = local_with_binding
  end : Runtime_contract.RUNTIME)

let run_eta_jsoo root body =
  let promise, resolver = create_promise () in
  let fiber =
    {
      fiber_id = fresh_id ();
      fiber_scope = root;
      fiber_cancel = root.scope_cancel;
      fiber_locals = Hashtbl.create 8;
      fiber_protect_depth = 0;
    }
  in
  let finish = function
    | Ok value -> resolve_once resolver value
    | Error (exn, _bt) -> reject_once resolver exn
  in
  schedule (fun () -> run_handled fiber body finish);
  promise

let subscribe_or_raise promise ~on_result =
  subscribe promise (function
    | Ok value -> on_result value
    | Error exn -> raise exn)

module Runtime = struct
  type 'err t = 'err Eta.Runtime.t

  let create ?sleep ?now_ms ?tracer ?sampler ?auto_instrument ?logger ?meter
      ?random ?services
      ?capture_backtrace () =
    Eta.Runtime.create_with_runtime (runtime ()) ?sleep ?now_ms ?tracer ?sampler
      ?auto_instrument ?logger ?meter ?random ?services ?capture_backtrace ()

  let run runtime eff ~on_result =
    run_eta_jsoo root_scope (fun () -> Eta.Runtime.run runtime eff)
    |> subscribe_or_raise ~on_result

  let run_exn runtime eff ~on_result =
    run runtime eff ~on_result:(function
      | Eta.Exit.Ok value -> on_result value
      | Eta.Exit.Error
          (Eta.Cause.Die { Eta.Cause.exn; backtrace = Some bt; _ }) ->
          Printexc.raise_with_backtrace exn bt
      | Eta.Exit.Error (Eta.Cause.Die { Eta.Cause.exn; backtrace = None; _ }) ->
          raise exn
      | Eta.Exit.Error cause ->
          failwith
            (Format.asprintf "Eta_jsoo.Runtime.run_exn: %a"
               (Eta.Cause.pp
                  (fun fmt _ -> Format.pp_print_string fmt "<typed failure>"))
               cause))

  let drain runtime ~on_result =
    run_eta_jsoo root_scope (fun () -> Eta.Runtime.drain runtime)
    |> subscribe_or_raise ~on_result
end

let run make_eff ~on_result =
  let runtime = Runtime.create () in
  Runtime.run_exn runtime (make_eff ()) ~on_result
