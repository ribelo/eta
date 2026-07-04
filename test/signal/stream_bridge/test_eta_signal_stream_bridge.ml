module Effect = Eta.Effect
module Queue = Eta.Queue
module Stream_bridge = Eta_signal_stream_bridge

type test_error = [ `Invalid_scope ]

let pp_hidden ppf _ = Format.pp_print_string ppf "<stream-bridge-error>"

let run_ok runtime eff =
  match Eta_eio.Runtime.run runtime eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Eta.Cause.pp pp_hidden) cause

let run_invalid_scope runtime eff =
  match Eta_eio.Runtime.run runtime eff with
  | Eta.Exit.Error (Eta.Cause.Fail `Invalid_scope) -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "expected Invalid_scope failure"
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Invalid_scope, got %a"
        (Eta.Cause.pp pp_hidden) cause

let test_capacity_validation () =
  Alcotest.(check bool) "zero rejected" true
    (Result.is_error (Stream_bridge.create_queue ~capacity:0));
  Alcotest.(check bool) "positive accepted" true
    (Result.is_ok (Stream_bridge.create_queue ~capacity:1))

let test_offer_sends_and_drops () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let queue =
    match Stream_bridge.create_queue ~capacity:1 with
    | Ok queue -> queue
    | Error _ -> Alcotest.fail "expected queue"
  in
  let sent = ref [] in
  let dropped = ref [] in
  let on_drop_seen = ref [] in
  let token = ref (Some 1) in
  let offer value =
    Stream_bridge.offer ~queue
      ~current_token:(fun () -> Effect.sync (fun () -> !token))
      ~acknowledge_sent:(fun token value ->
        Effect.sync (fun () -> sent := (token, value) :: !sent))
      ~acknowledge_drop:(fun token value ->
        Effect.sync (fun () -> dropped := (token, value) :: !dropped))
      ~after_try_send_before_ack:(fun () -> Effect.unit)
      ~after_drop_before_ack:(fun () -> Effect.unit)
      ~on_closed_with_error:(fun `Invalid_scope -> Effect.fail `Invalid_scope)
      ~on_drop:(Some (fun value -> on_drop_seen := value :: !on_drop_seen))
      value
  in
  run_ok runtime (offer 1);
  run_ok runtime (offer 2);
  Alcotest.(check (list (pair int int))) "sent ack" [ (1, 1) ] !sent;
  Alcotest.(check (list (pair int int))) "drop ack" [ (1, 2) ] !dropped;
  Alcotest.(check (list int)) "on_drop" [ 2 ] !on_drop_seen;
  match run_ok runtime (Queue.try_recv queue) with
  | `Item value -> Alcotest.(check int) "queued value" 1 value
  | `Empty | `Closed | `Closed_with_error _ ->
      Alcotest.fail "expected queued item"

let test_offer_without_token_noops () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let queue =
    match Stream_bridge.create_queue ~capacity:1 with
    | Ok queue -> queue
    | Error _ -> Alcotest.fail "expected queue"
  in
  let sent = ref [] in
  let dropped = ref [] in
  let after_send = ref false in
  let after_drop = ref false in
  let offer =
    Stream_bridge.offer ~queue
      ~current_token:(fun () -> Effect.sync (fun () -> None))
      ~acknowledge_sent:(fun token value ->
        Effect.sync (fun () -> sent := (token, value) :: !sent))
      ~acknowledge_drop:(fun token value ->
        Effect.sync (fun () -> dropped := (token, value) :: !dropped))
      ~after_try_send_before_ack:(fun () ->
        Effect.sync (fun () -> after_send := true))
      ~after_drop_before_ack:(fun () ->
        Effect.sync (fun () -> after_drop := true))
      ~on_closed_with_error:(fun `Invalid_scope -> Effect.fail `Invalid_scope)
      ~on_drop:None 1
  in
  run_ok runtime offer;
  Alcotest.(check (list (pair int int))) "sent ack" [] !sent;
  Alcotest.(check (list (pair int int))) "drop ack" [] !dropped;
  Alcotest.(check bool) "after send skipped" false !after_send;
  Alcotest.(check bool) "after drop skipped" false !after_drop;
  match run_ok runtime (Queue.try_recv queue) with
  | `Empty -> ()
  | `Item _ | `Closed | `Closed_with_error _ ->
      Alcotest.fail "expected empty queue"

let test_drop_ack_runs_once_after_failure () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let queue =
    match Stream_bridge.create_queue ~capacity:1 with
    | Ok queue -> queue
    | Error _ -> Alcotest.fail "expected queue"
  in
  let sent = ref [] in
  let dropped = ref [] in
  let on_drop_seen = ref [] in
  let offer ~after_drop value =
    Stream_bridge.offer ~queue
      ~current_token:(fun () -> Effect.sync (fun () -> Some 1))
      ~acknowledge_sent:(fun token value ->
        Effect.sync (fun () -> sent := (token, value) :: !sent))
      ~acknowledge_drop:(fun token value ->
        Effect.sync (fun () -> dropped := (token, value) :: !dropped))
      ~after_try_send_before_ack:(fun () -> Effect.unit)
      ~after_drop_before_ack:after_drop
      ~on_closed_with_error:(fun `Invalid_scope -> Effect.fail `Invalid_scope)
      ~on_drop:(Some (fun value -> on_drop_seen := value :: !on_drop_seen))
      value
  in
  run_ok runtime (offer ~after_drop:(fun () -> Effect.unit) 1);
  run_invalid_scope runtime
    (offer ~after_drop:(fun () -> Effect.fail `Invalid_scope) 2);
  Alcotest.(check (list (pair int int))) "sent ack" [ (1, 1) ] !sent;
  Alcotest.(check (list (pair int int))) "drop ack once" [ (1, 2) ]
    !dropped;
  Alcotest.(check (list int)) "on_drop once" [ 2 ] !on_drop_seen;
  match run_ok runtime (Queue.try_recv queue) with
  | `Item value -> Alcotest.(check int) "queued value" 1 value
  | `Empty | `Closed | `Closed_with_error _ ->
      Alcotest.fail "expected original queued item"

let () =
  Alcotest.run "eta_signal_stream_bridge"
    [
      ( "stream_bridge",
        [
          Alcotest.test_case "capacity validation" `Quick
            test_capacity_validation;
          Alcotest.test_case "offer sends and drops" `Quick
            test_offer_sends_and_drops;
          Alcotest.test_case "offer without token noops" `Quick
            test_offer_without_token_noops;
          Alcotest.test_case "drop ack runs once after failure" `Quick
            test_drop_ack_runs_once_after_failure;
        ] );
    ]
