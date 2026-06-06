type scope = Obj.t
type cancel_context = Obj.t
type 'a promise = Obj.t
type 'a resolver = Obj.t
type 'a stream = Obj.t
type 'a local = int
type 'a service_key = int
type service = Service : 'a service_key * 'a -> service

type t = {
  root_scope : scope;
  now_ms : unit -> int;
  sleep : Duration.t -> unit;
  protect : 'a. (unit -> 'a) -> 'a;
  run_scope : 'a. ?name:string -> (scope -> 'a) -> 'a;
  fail_scope : ?bt:Printexc.raw_backtrace -> scope -> exn -> unit;
  fork : scope -> (unit -> unit) -> unit;
  fork_daemon : scope -> (unit -> [ `Stop_daemon ]) -> unit;
  await_cancel : 'a. unit -> 'a;
  yield : unit -> unit;
  check : unit -> unit;
  create_promise : 'a. unit -> 'a promise * 'a resolver;
  resolve_promise : 'a. 'a resolver -> 'a -> unit;
  await_promise : 'a. 'a promise -> 'a;
  create_stream : 'a. int -> 'a stream;
  stream_add : 'a. 'a stream -> 'a -> unit;
  stream_take : 'a. 'a stream -> 'a;
  stream_take_nonblocking : 'a. 'a stream -> 'a option;
  with_worker_context : 'a. (unit -> 'a) -> 'a;
  in_worker_context : unit -> bool;
  cancellation_reason : exn -> exn option;
  multiple_exceptions : exn -> (exn * Printexc.raw_backtrace) list option;
  cancel_sub : 'a. (cancel_context -> 'a) -> 'a;
  cancel : cancel_context -> exn -> unit;
  local_get : 'a. 'a local -> 'a option;
  local_with_binding : 'a 'b. 'a local -> 'a -> (unit -> 'b) -> 'b;
}

module type RUNTIME = sig
  type scope
  type cancel_context
  type 'a promise
  type 'a resolver
  type 'a stream

  val root_scope : scope
  val now_ms : unit -> int
  val sleep : Duration.t -> unit
  val protect : (unit -> 'a) -> 'a
  val run_scope : ?name:string -> (scope -> 'a) -> 'a
  val fail_scope : ?bt:Printexc.raw_backtrace -> scope -> exn -> unit
  val fork : scope -> (unit -> unit) -> unit
  val fork_daemon : scope -> (unit -> [ `Stop_daemon ]) -> unit
  val await_cancel : unit -> 'a
  val yield : unit -> unit
  val check : unit -> unit
  val create_promise : unit -> 'a promise * 'a resolver
  val resolve_promise : 'a resolver -> 'a -> unit
  val await_promise : 'a promise -> 'a
  val create_stream : int -> 'a stream
  val stream_add : 'a stream -> 'a -> unit
  val stream_take : 'a stream -> 'a
  val stream_take_nonblocking : 'a stream -> 'a option
  val with_worker_context : (unit -> 'a) -> 'a
  val in_worker_context : unit -> bool
  val cancellation_reason : exn -> exn option
  val multiple_exceptions : exn -> (exn * Printexc.raw_backtrace) list option
  val cancel_sub : (cancel_context -> 'a) -> 'a
  val cancel : cancel_context -> exn -> unit
  val local_get : 'a local -> 'a option
  val local_with_binding : 'a local -> 'a -> (unit -> 'b) -> 'b
end

let next_local = Atomic.make 0
let create_local () = Atomic.fetch_and_add next_local 1

let next_service_key = Atomic.make 0
let create_service_key () = Atomic.fetch_and_add next_service_key 1

let worker_context_probes : (unit -> bool) list Atomic.t = Atomic.make []

let rec register_worker_context_probe probe =
  let probes = Atomic.get worker_context_probes in
  if not (Atomic.compare_and_set worker_context_probes probes (probe :: probes))
  then register_worker_context_probe probe

let in_registered_worker_context () =
  List.exists
    (fun probe -> try probe () with _ -> false)
    (Atomic.get worker_context_probes)

module Backend = struct
  let local_id local = local
  let service_key_id key = key
  let scope value = value
  let scope_value value = value
  let cancel_context value = value
  let cancel_context_value value = value
  let promise value = value
  let promise_value value = value
  let resolver value = value
  let resolver_value value = value
  let stream value = value
  let stream_value value = value
end

let of_runtime (module R : RUNTIME) =
  let scope_value scope =
    (Obj.obj (Backend.scope_value scope) : R.scope)
  in
  let cancel_context_value cancel_context =
    (Obj.obj (Backend.cancel_context_value cancel_context) : R.cancel_context)
  in
  {
    root_scope = Backend.scope (Obj.repr R.root_scope);
    now_ms = R.now_ms;
    sleep = R.sleep;
    protect = R.protect;
    run_scope =
      (fun ?name f ->
        R.run_scope ?name @@ fun scope -> f (Backend.scope (Obj.repr scope)));
    fail_scope =
      (fun ?bt scope exn -> R.fail_scope ?bt (scope_value scope) exn);
    fork = (fun scope f -> R.fork (scope_value scope) f);
    fork_daemon = (fun scope f -> R.fork_daemon (scope_value scope) f);
    await_cancel = (fun () -> R.await_cancel ());
    yield = R.yield;
    check = R.check;
    create_promise =
      (fun (type a) () ->
        let promise, resolver = R.create_promise () in
        (Backend.promise (Obj.repr promise), Backend.resolver (Obj.repr resolver)));
    resolve_promise =
      (fun (type a) (resolver : a resolver) (value : a) ->
        let resolver =
          (Obj.obj (Backend.resolver_value resolver) : a R.resolver)
        in
        R.resolve_promise resolver value);
    await_promise =
      (fun (type a) (promise : a promise) ->
        let promise =
          (Obj.obj (Backend.promise_value promise) : a R.promise)
        in
        R.await_promise promise);
    create_stream =
      (fun (type a) capacity ->
        Backend.stream (Obj.repr (R.create_stream capacity : a R.stream)));
    stream_add =
      (fun (type a) (stream : a stream) (value : a) ->
        let stream =
          (Obj.obj (Backend.stream_value stream) : a R.stream)
        in
        R.stream_add stream value);
    stream_take =
      (fun (type a) (stream : a stream) ->
        let stream =
          (Obj.obj (Backend.stream_value stream) : a R.stream)
        in
        R.stream_take stream);
    stream_take_nonblocking =
      (fun (type a) (stream : a stream) ->
        let stream =
          (Obj.obj (Backend.stream_value stream) : a R.stream)
        in
        R.stream_take_nonblocking stream);
    with_worker_context = R.with_worker_context;
    in_worker_context = R.in_worker_context;
    cancellation_reason = R.cancellation_reason;
    multiple_exceptions = R.multiple_exceptions;
    cancel_sub =
      (fun f ->
        R.cancel_sub @@ fun cancel ->
        f (Backend.cancel_context (Obj.repr cancel)));
    cancel =
      (fun cancel_context exn ->
        R.cancel (cancel_context_value cancel_context) exn);
    local_get = R.local_get;
    local_with_binding = R.local_with_binding;
  }
