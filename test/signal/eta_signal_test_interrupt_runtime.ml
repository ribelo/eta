open Eta

exception Cleanup_interrupt

type scope = unit
type cancel_context = unit
type 'a promise = 'a option ref
type 'a resolver = 'a option ref
type 'a stream = 'a Stdlib.Queue.t

let interrupt_next_protect_return = ref false
let interrupt_on_protect_count = ref None
let protect_count = ref 0
let interrupt_on_local_binding_count = ref None
let after_local_binding_count : (int * (unit -> unit)) option ref = ref None
let defer_daemons = ref false
let deferred_daemons : (unit -> [ `Stop_daemon ]) Stdlib.Queue.t =
  Stdlib.Queue.create ()
let now = ref 0
let fresh_counter = Atomic.make 0
let root_scope = ()
let now_ms () = !now
let fresh () = Atomic.fetch_and_add fresh_counter 1 + 1
let sleep duration = now := !now + Duration.to_ms duration

let protect f =
  let value = f () in
  protect_count := !protect_count + 1;
  let interrupt_next = !interrupt_next_protect_return in
  if interrupt_next then interrupt_next_protect_return := false;
  let interrupt_count =
    match !interrupt_on_protect_count with
    | Some target when target = !protect_count ->
        interrupt_on_protect_count := None;
        true
    | Some _ | None -> false
  in
  if interrupt_next || interrupt_count then (
    interrupt_next_protect_return := false;
    raise Cleanup_interrupt);
  value

let with_cancel_mask f =
  protect (fun () ->
      f
        {
          Runtime_contract.restore =
            (fun (type a) (body : unit -> a) -> body ());
        })

let run_scope ?name:_ f = f ()
let fail_scope ?bt:_ () exn = raise exn
let fork () f = f ()
let fork_daemon () f =
  if !defer_daemons then Stdlib.Queue.add f deferred_daemons
  else ignore (f () : [ `Stop_daemon ])
let await_cancel () = raise Cleanup_interrupt
let yield () = ()
let check () = ()

let create_promise () =
  let cell = ref None in
  (cell, cell)

let resolve_promise resolver value =
  match !resolver with
  | Some _ ->
      invalid_arg "Cleanup_interrupt_runtime.resolve_promise: already resolved"
  | None -> resolver := Some value

let await_promise promise =
  match !promise with
  | Some value -> value
  | None -> failwith "Cleanup_interrupt_runtime.await_promise: unresolved"

let create_stream _capacity = Stdlib.Queue.create ()
let stream_add stream value = Stdlib.Queue.add value stream

let stream_take stream =
  if Stdlib.Queue.is_empty stream then
    failwith "Cleanup_interrupt_runtime.stream_take: empty"
  else Stdlib.Queue.take stream

let stream_take_nonblocking stream =
  if Stdlib.Queue.is_empty stream then None else Some (Stdlib.Queue.take stream)

let with_worker_context f = f ()
let in_worker_context () = false

let cancellation_reason = function
  | Cleanup_interrupt -> Some Cleanup_interrupt
  | _ -> None

let multiple_exceptions _ = None
let cancel_sub f = f ()
let cancel () exn = raise exn
let current_fiber_id () = 0
let with_fiber_identity f = f ()

let locals : (int, Runtime_contract.local_binding list) Hashtbl.t =
  Hashtbl.create 8

let local_binding_count = ref 0

let local_get local =
  match Hashtbl.find_opt locals (Runtime_contract.Backend.local_id local) with
  | None -> None
  | Some bindings ->
      List.find_map
        (Runtime_contract.Backend.local_binding_value local)
        bindings

let local_with_binding local value f =
  let id = Runtime_contract.Backend.local_id local in
  let previous = Hashtbl.find_opt locals id in
  let stack = Option.value previous ~default:[] in
  local_binding_count := !local_binding_count + 1;
  Hashtbl.replace locals id
    (Runtime_contract.Local_binding (local, value) :: stack);
  let interrupt =
    match !interrupt_on_local_binding_count with
    | Some target when target = !local_binding_count ->
        interrupt_on_local_binding_count := None;
        true
    | Some _ | None -> false
  in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some stack -> Hashtbl.replace locals id stack
      | None -> Hashtbl.remove locals id)
    (fun () -> if interrupt then raise Cleanup_interrupt else f ())
  |> fun value ->
  (match !after_local_binding_count with
   | Some (target, hook) when target = !local_binding_count ->
       after_local_binding_count := None;
       hook ()
   | Some _ | None -> ());
  value
