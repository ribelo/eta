open Eta

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
