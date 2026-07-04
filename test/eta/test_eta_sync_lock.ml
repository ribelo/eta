open Eta
open Test_eta_support

exception Sync_lock_reentry_timeout

let with_reentry_alarm f =
  let previous =
    Sys.Safe.signal Sys.sigalrm
      (Sys.Signal_handle (fun _ -> raise Sync_lock_reentry_timeout))
  in
  ignore (Unix.alarm 1 : int);
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.alarm 0 : int);
      Sys.Safe.set_signal Sys.sigalrm previous)
    f

let test_sync_lock_reentrant_use_fails_fast () =
  let lock = Sync_lock.create () in
  let result =
    try
      with_reentry_alarm @@ fun () ->
      Sync_lock.use lock @@ fun () -> Sync_lock.use lock (fun () -> ());
      `Returned
    with
    | Invalid_argument message -> `Invalid_argument message
    | Sync_lock_reentry_timeout -> `Timed_out
    | exn -> `Unexpected exn
  in
  (match result with
  | `Invalid_argument message ->
      Alcotest.(check string)
        "reentry failure"
        "Eta.Sync_lock: reentrant lock acquisition" message
  | `Timed_out ->
      Alcotest.fail "reentrant lock acquisition spun until the watchdog fired"
  | `Unexpected exn ->
      Alcotest.failf "unexpected exception: %s" (Printexc.to_string exn)
  | `Returned -> Alcotest.fail "reentrant lock acquisition returned");
  Alcotest.(check int) "lock remains usable" 1
    (Sync_lock.use lock (fun () -> 1))

let test_sync_lock_cross_domain_contention_waits () =
  let lock = Sync_lock.create () in
  let started = Atomic.make false in
  let acquired = Atomic.make false in
  let waiter =
    Sync_lock.use lock @@ fun () ->
    let waiter =
      (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
        (fun () ->
          Atomic.set started true;
          Sync_lock.use lock @@ fun () -> Atomic.set acquired true)
    in
    while not (Atomic.get started) do
      Domain.cpu_relax ()
    done;
    Alcotest.(check bool) "waiter did not enter while held" false
      (Atomic.get acquired);
    waiter
  in
  Domain.join waiter;
  Alcotest.(check bool) "waiter entered after release" true (Atomic.get acquired)

let test_sync_lock_rejects_runtime_operation () =
  with_runtime @@ fun rt ->
  let lock = Sync_lock.create () in
  let result =
    try
      Sync_lock.use lock @@ fun () ->
      ignore (Runtime.run rt Effect.yield : (unit, string) Exit.t);
      `Returned
    with Invalid_argument message -> `Invalid_argument message
  in
  match result with
  | `Invalid_argument message ->
      Alcotest.(check string)
        "runtime operation under lock"
        "Eta.Sync_lock: runtime operation attempted while holding lock"
        message
  | `Returned -> Alcotest.fail "runtime operation under Sync_lock returned"

let test_sync_lock_rejects_runtime_contract_operation () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let contract =
    Runtime_contract.of_runtime
      (Eta_eio.runtime ~sw ~clock:(Eio.Stdenv.clock stdenv))
  in
  let lock = Sync_lock.create () in
  let result =
    try
      Sync_lock.use lock @@ fun () ->
      contract.yield ();
      `Returned
    with Invalid_argument message -> `Invalid_argument message
  in
  match result with
  | `Invalid_argument message ->
      Alcotest.(check string)
        "runtime contract operation under lock"
        "Eta.Sync_lock: runtime operation attempted while holding lock"
        message
  | `Returned ->
      Alcotest.fail "runtime contract operation under Sync_lock returned"
