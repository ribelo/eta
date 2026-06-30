let foreign_runtime_token = "Eta.Runtime_contract: foreign runtime token"

type runtime_id = Runtime_id of int

module Erased_token = struct
  type ('kind, 'payload) t = {
    runtime_id : runtime_id;
    value : Obj.t;
  }

  let make runtime_id value = { runtime_id; value = Obj.repr value }

  let cast runtime_id token =
    if token.runtime_id <> runtime_id then invalid_arg foreign_runtime_token;
    Obj.obj token.value
end

type scope_token
type cancel_context_token
type promise_token
type resolver_token
type stream_token

type scope = Scope of (scope_token, unit) Erased_token.t
type cancel_context = Cancel_context of (cancel_context_token, unit) Erased_token.t
type 'a promise = Promise of (promise_token, 'a) Erased_token.t
type 'a resolver = Resolver of (resolver_token, 'a) Erased_token.t
type 'a stream = Stream of (stream_token, 'a) Erased_token.t
type 'a local = 'a Type.Id.t
type local_binding = Local_binding : 'a local * 'a -> local_binding
type 'a service_key = 'a Type.Id.t
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
let create_local () =
  ignore (Atomic.fetch_and_add next_local 1);
  Type.Id.make ()

let next_service_key = Atomic.make 0
let create_service_key () =
  ignore (Atomic.fetch_and_add next_service_key 1);
  Type.Id.make ()

let next_runtime_id = Atomic.make 0
let wrong_domain =
  "Eta.Runtime_contract: runtime contract APIs must be called on the domain "
  ^ "that created the contract"

let fresh_runtime_id () = Runtime_id (Atomic.fetch_and_add next_runtime_id 1)

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
  let local_id local = Type.Id.uid local
  let local_binding_value : type a. a local -> local_binding -> a option =
   fun local (Local_binding (stored_local, value)) ->
    match Type.Id.provably_equal local stored_local with
    | Some Type.Equal -> Some value
    | None -> None

  let service_key_id key = Type.Id.uid key
  let service_value : type a. a service_key -> service -> a option =
   fun key (Service (stored_key, value)) ->
    match Type.Id.provably_equal key stored_key with
    | Some Type.Equal -> Some value
    | None -> None

end

let of_runtime (module R : RUNTIME) =
  let runtime_id = fresh_runtime_id () in
  let owner_domain = Domain.self () in
  let ensure_owner_domain () =
    if Domain.self () <> owner_domain then invalid_arg wrong_domain
  in
  let scope value = Scope (Erased_token.make runtime_id value) in
  let cancel_context value =
    Cancel_context (Erased_token.make runtime_id value)
  in
  let promise value = Promise (Erased_token.make runtime_id value) in
  let resolver value = Resolver (Erased_token.make runtime_id value) in
  let stream value = Stream (Erased_token.make runtime_id value) in
  let scope_value (Scope token) =
    (Erased_token.cast runtime_id token : R.scope)
  in
  let cancel_context_value (Cancel_context token) =
    (Erased_token.cast runtime_id token : R.cancel_context)
  in
  let promise_value : type a. a promise -> a R.promise =
   fun (Promise token) -> Erased_token.cast runtime_id token
  in
  let resolver_value : type a. a resolver -> a R.resolver =
   fun (Resolver token) -> Erased_token.cast runtime_id token
  in
  let stream_value : type a. a stream -> a R.stream =
   fun (Stream token) -> Erased_token.cast runtime_id token
  in
  {
    root_scope = scope R.root_scope;
    now_ms =
      (fun () ->
        ensure_owner_domain ();
        R.now_ms ());
    sleep =
      (fun duration ->
        ensure_owner_domain ();
        R.sleep duration);
    protect =
      (fun f ->
        ensure_owner_domain ();
        R.protect @@ fun () ->
        ensure_owner_domain ();
        f ());
    run_scope =
      (fun ?name f ->
        ensure_owner_domain ();
        R.run_scope ?name @@ fun child_scope ->
        ensure_owner_domain ();
        f (scope child_scope));
    fail_scope =
      (fun ?bt scope exn ->
        ensure_owner_domain ();
        R.fail_scope ?bt (scope_value scope) exn);
    fork =
      (fun scope f ->
        ensure_owner_domain ();
        R.fork (scope_value scope) (fun () ->
            ensure_owner_domain ();
            f ()));
    fork_daemon =
      (fun scope f ->
        ensure_owner_domain ();
        R.fork_daemon (scope_value scope) (fun () ->
            ensure_owner_domain ();
            f ()));
    await_cancel =
      (fun () ->
        ensure_owner_domain ();
        R.await_cancel ());
    yield =
      (fun () ->
        ensure_owner_domain ();
        R.yield ());
    check =
      (fun () ->
        ensure_owner_domain ();
        R.check ());
    create_promise =
      (fun (type a) () ->
        ensure_owner_domain ();
        let raw_promise, raw_resolver = R.create_promise () in
        (promise raw_promise, resolver raw_resolver));
    resolve_promise =
      (fun (type a) (resolver : a resolver) (value : a) ->
        ensure_owner_domain ();
        R.resolve_promise (resolver_value resolver) value);
    await_promise =
      (fun (type a) (promise : a promise) ->
        ensure_owner_domain ();
        let value = R.await_promise (promise_value promise) in
        ensure_owner_domain ();
        value);
    create_stream =
      (fun (type a) capacity ->
        ensure_owner_domain ();
        stream (R.create_stream capacity : a R.stream));
    stream_add =
      (fun (type a) (stream : a stream) (value : a) ->
        ensure_owner_domain ();
        R.stream_add (stream_value stream) value);
    stream_take =
      (fun (type a) (stream : a stream) ->
        ensure_owner_domain ();
        let value = R.stream_take (stream_value stream) in
        ensure_owner_domain ();
        value);
    stream_take_nonblocking =
      (fun (type a) (stream : a stream) ->
        ensure_owner_domain ();
        let value = R.stream_take_nonblocking (stream_value stream) in
        ensure_owner_domain ();
        value);
    with_worker_context = R.with_worker_context;
    in_worker_context = R.in_worker_context;
    cancellation_reason = R.cancellation_reason;
    multiple_exceptions = R.multiple_exceptions;
    cancel_sub =
      (fun f ->
        ensure_owner_domain ();
        R.cancel_sub @@ fun cancel ->
        ensure_owner_domain ();
        f (cancel_context cancel));
    cancel =
      (fun cancel_context exn ->
        ensure_owner_domain ();
        R.cancel (cancel_context_value cancel_context) exn);
    local_get =
      (fun local ->
        ensure_owner_domain ();
        R.local_get local);
    local_with_binding =
      (fun local value f ->
        ensure_owner_domain ();
        R.local_with_binding local value (fun () ->
            ensure_owner_domain ();
            f ()));
  }
