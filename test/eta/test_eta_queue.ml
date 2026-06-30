open Eta

exception Promise_blocked
exception Await_cancelled
exception Reentered_locked_queue

module Hooked_runtime = struct
  type scope = unit
  type cancel_context = unit
  type 'a promise = 'a option ref
  type 'a resolver = 'a option ref
  type 'a stream = 'a Stdlib.Queue.t

  let resolve_hook = ref (fun () -> ())
  let await_hook = ref (fun () -> ())
  let cancel_after_resolved_await = ref false
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
    if Option.is_none !promise then !await_hook ();
    match !promise with
    | Some value ->
        if !cancel_after_resolved_await then (
          cancel_after_resolved_await := false;
          raise Await_cancelled);
        value
    | None -> raise Promise_blocked

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
  let cancellation_reason = function
    | Await_cancelled -> Some Await_cancelled
    | _ -> None
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

let run_in_domain f =
  let domain =
    (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
      f
  in
  Domain.join domain

let test_queue_rejects_cross_domain_use () =
  let queue = Queue.create () in
  match
    run_in_domain @@ fun () ->
    try Ok (ignore (Queue.stats queue : Queue.stats))
    with
    | Invalid_argument message -> Error message
    | exn ->
        Alcotest.failf "expected Invalid_argument, got %s"
          (Printexc.to_string exn)
  with
  | Error message ->
      Alcotest.(check string)
        "cross-domain queue failure"
        "Eta.Queue: queue APIs must be called on the domain that created the queue"
        message
  | Ok () -> Alcotest.fail "expected cross-domain queue use to fail"

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

let reset_hooked_runtime () =
  Hooked_runtime.resolve_hook := (fun () -> ());
  Hooked_runtime.await_hook := (fun () -> ());
  Hooked_runtime.cancel_after_resolved_await := false

let test_queue_backpressure_admission_wins_racing_cancellation () =
  let rt = Test_runtime.create () in
  let queue = Queue.create ~overflow:(Queue.Backpressure { capacity = 1 }) () in
  Alcotest.(check bool) "initial offer" true (run_ok rt (Queue.offer queue 1));
  let await_hook_ran = ref false in
  Fun.protect
    ~finally:reset_hooked_runtime
    (fun () ->
      Hooked_runtime.await_hook :=
        (fun () ->
          await_hook_ran := true;
          Hooked_runtime.await_hook := (fun () -> ());
          Alcotest.(check int)
            "first value opened capacity" 1
            (run_ok rt (Queue.recv queue));
          Hooked_runtime.cancel_after_resolved_await := true);
      match Test_runtime.run rt (Queue.offer queue 2) with
      | Exit.Ok true -> ()
      | Exit.Ok false -> Alcotest.fail "admitted backpressure offer returned false"
      | Exit.Error cause ->
          Alcotest.failf "expected admitted offer, got %a"
            (Cause.pp pp_hidden) cause
      | exception Await_cancelled ->
          Alcotest.fail
            "cancellation after queue admission made the sender look uncommitted");
  Alcotest.(check bool) "await hook ran" true !await_hook_ran;
  Alcotest.(check int) "admitted value remains exactly once" 2
    (run_ok rt (Queue.recv queue));
  let stats = Queue.stats queue in
  Alcotest.(check int) "no waiting sender remains" 0 stats.Queue.waiting_senders;
  Alcotest.(check int) "admitted sender not counted cancelled" 0
    stats.Queue.cancelled_senders

let set_queue_counter queue field value =
  (* Public APIs cannot drive stats counters to [max_int] in a focused test. *)
  Obj.set_field (Obj.repr queue) field (Obj.repr value)

let test_queue_stats_counters_saturate () =
  let rt = Test_runtime.create () in
  let sent_queue = Queue.create () in
  set_queue_counter sent_queue 7 (max_int - 1);
  run_ok rt (Queue.send sent_queue 1);
  run_ok rt (Queue.send sent_queue 2);
  Alcotest.(check int) "sent saturates" max_int
    (Queue.stats sent_queue).Queue.sent;
  let received_queue = Queue.create () in
  run_ok rt (Queue.send received_queue 1);
  run_ok rt (Queue.send received_queue 2);
  set_queue_counter received_queue 8 (max_int - 1);
  Alcotest.(check int) "first received value" 1
    (run_ok rt (Queue.recv received_queue));
  Alcotest.(check int) "second received value" 2
    (run_ok rt (Queue.recv received_queue));
  Alcotest.(check int) "received saturates" max_int
    (Queue.stats received_queue).Queue.received;
  let dropped_queue = Queue.create ~overflow:(Queue.Drop_new { capacity = 1 }) () in
  run_ok rt (Queue.send dropped_queue 1);
  set_queue_counter dropped_queue 9 (max_int - 1);
  Alcotest.(check bool) "first drop" false
    (run_ok rt (Queue.offer dropped_queue 2));
  Alcotest.(check bool) "second drop" false
    (run_ok rt (Queue.offer dropped_queue 3));
  Alcotest.(check int) "dropped saturates" max_int
    (Queue.stats dropped_queue).Queue.dropped
