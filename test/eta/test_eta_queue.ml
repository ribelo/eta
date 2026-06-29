open Eta

exception Promise_blocked
exception Reentered_locked_queue

module Hooked_runtime = struct
  type scope = unit
  type cancel_context = unit
  type 'a promise = 'a option ref
  type 'a resolver = 'a option ref
  type 'a stream = 'a Stdlib.Queue.t

  let resolve_hook = ref (fun () -> ())
  let root_scope = ()
  let now_ms () = 0
  let sleep _ = ()
  let protect f = f ()
  let run_scope ?name:_ f = f ()
  let fail_scope ?bt:_ () exn = raise exn
  let fork () f = f ()
  let fork_daemon () f = ignore (f () : [ `Stop_daemon ])
  let await_cancel () = raise Promise_blocked
  let yield () = ()
  let check () = ()

  let create_promise () =
    let cell = ref None in
    (cell, cell)

  let resolve_promise resolver value =
    !resolve_hook ();
    match !resolver with
    | Some _ -> invalid_arg "Hooked_runtime.resolve_promise: already resolved"
    | None -> resolver := Some value

  let await_promise promise =
    match !promise with Some value -> value | None -> raise Promise_blocked

  let create_stream _capacity = Stdlib.Queue.create ()
  let stream_add stream value = Stdlib.Queue.add value stream

  let stream_take stream =
    if Stdlib.Queue.is_empty stream then
      failwith "Hooked_runtime.stream_take: empty"
    else Stdlib.Queue.take stream

  let stream_take_nonblocking stream =
    if Stdlib.Queue.is_empty stream then None else Some (Stdlib.Queue.take stream)

  let with_worker_context f = f ()
  let in_worker_context () = false
  let cancellation_reason _ = None
  let multiple_exceptions _ = None
  let cancel_sub f = f ()
  let cancel () exn = raise exn
  let local_get _ = None
  let local_with_binding _ _ f = f ()
end

module Test_runtime = Runtime.Make (Hooked_runtime)

let pp_hidden ppf _ = Format.pp_print_string ppf "<err>"

let run_ok rt eff =
  match Test_runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

let expect_blocked = function
  | Exit.Error (Cause.Die { exn = Promise_blocked; _ }) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected blocked promise defect, got %a"
        (Cause.pp pp_hidden) cause
  | Exit.Ok _ -> Alcotest.fail "expected blocked promise defect"

let with_reentry_alarm f =
  let previous =
    Sys.Safe.signal Sys.sigalrm
      (Sys.Signal_handle (fun _ -> raise Reentered_locked_queue))
  in
  ignore (Unix.alarm 1 : int);
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.alarm 0 : int);
      Sys.Safe.set_signal Sys.sigalrm previous)
    f

let test_queue_resolves_sender_outside_lock () =
  let rt = Test_runtime.create () in
  let queue = Queue.create ~overflow:(Queue.Backpressure { capacity = 1 }) () in
  Alcotest.(check bool) "first offer" true (run_ok rt (Queue.offer queue 1));
  expect_blocked (Test_runtime.run rt (Queue.offer queue 2));
  Alcotest.(check int) "sender waits" 1 (Queue.stats queue).Queue.waiting_senders;
  let hook_ran = ref false in
  Hooked_runtime.resolve_hook :=
    (fun () ->
      hook_ran := true;
      ignore (Queue.stats queue : Queue.stats));
  let first =
    Fun.protect
      ~finally:(fun () -> Hooked_runtime.resolve_hook := (fun () -> ()))
      (fun () ->
        try with_reentry_alarm (fun () -> run_ok rt (Queue.recv queue))
        with Reentered_locked_queue ->
          Alcotest.fail "queue resolver re-entered while the queue lock was held")
  in
  Alcotest.(check int) "first recv" 1 first;
  Alcotest.(check bool) "resolver hook ran" true !hook_ran;
  Alcotest.(check int) "admitted blocked sender" 2
    (run_ok rt (Queue.recv queue))
