module Crux = Eta_crux
module Harness = Eta_crux_test.Projection_harness
module Recipient = Harness.Wire_recipient

let run_ok runtime effect =
  Eta.Runtime.run runtime effect |> Eta_test.Expect.expect_ok

let codec encode decode =
  Crux.Codec.make
    ~encode:(fun value -> Ok (Bytes.of_string (encode value)))
    ~decode:(fun bytes ->
      match decode (Bytes.to_string bytes) with
      | Some value -> Ok value
      | None -> Error { Crux.Codec.message = "invalid projection wire value" })

let int_codec = codec string_of_int int_of_string_opt

let unit_codec =
  codec (fun () -> "") (fun value -> if String.equal value "" then Some () else None)

let serialized_driver ?(max_frame_bytes = 4_096) root =
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes
      ~format:(module Eta_crux_json.Format)
  in
  let binding, admin =
    Crux.Driver.Binding.serialized ~operations:[] ~session:candidate
  in
  (Crux.Driver.create binding root, admin, peer)

let receive runtime peer frame =
  frame |> Eta_crux_json.Format.encode
  |> Crux.Serialized_session.receive peer
  |> run_ok runtime

let poll_frame runtime peer =
  match run_ok runtime (Crux.Serialized_session.poll_outgoing peer) with
  | None -> None
  | Some bytes -> (
      match Eta_crux_json.Format.decode bytes with
      | Ok frame -> Some (frame, bytes)
      | Error _ -> Alcotest.fail "outgoing projection frame did not decode")

let acknowledge_projection runtime driver peer =
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let sequence =
    match poll_frame runtime peer with
    | Some (Crux.Wire.Frame.Projection_deliver { seq; _ }, _) -> seq
    | Some _ | None -> Alcotest.fail "projection delivery frame missing"
  in
  Alcotest.(check bool) "projection result accepted" true
    (receive runtime peer
       (Crux.Wire.Frame.Projection_result
          { seq = 0l; reply_to = sequence; result = `Accepted })
    = Ok ());
  ignore (run_ok runtime (Crux.Driver.poll driver))

let contains_substring value substring =
  let value_length = String.length value in
  let substring_length = String.length substring in
  let rec loop offset =
    offset + substring_length <= value_length
    &&
    (String.sub value offset substring_length = substring
    || loop (offset + 1))
  in
  substring_length = 0 || loop 0

let settle_serialized_crash ?forbidden ?(result_seq = 0l) runtime driver peer =
  let rec await_notification attempts =
    match poll_frame runtime peer with
    | Some
        (Crux.Wire.Frame.Crash_notify { seq; failure }, bytes) ->
        Option.iter
          (fun forbidden ->
            let rendered =
              Format.asprintf "%a"
                (Eta.Cause.Portable.pp Format.pp_print_string)
                failure.primary.cause
            in
            if
              contains_substring (Bytes.to_string bytes) forbidden
              || contains_substring rendered forbidden
            then
              Alcotest.fail
                "local projection diagnostic entered a crash frame")
          forbidden;
        seq
    | Some _ -> await_notification (attempts - 1)
    | None when attempts = 0 ->
        Alcotest.fail "serialized crash notification missing"
    | None ->
        ignore (run_ok runtime (Crux.Driver.poll driver));
        await_notification (attempts - 1)
  in
  let sequence = await_notification 20 in
  Alcotest.(check bool) "crash result accepted" true
    (receive runtime peer
       (Crux.Wire.Frame.Crash_result
          { seq = result_seq; reply_to = sequence; result = `Accepted })
    = Ok ());
  let rec await_closed attempts =
    match run_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Closed (Crux.Driver.Crashed settlement)) ->
        settlement
    | Some (Crux.Driver.Closed Crux.Driver.Stopped) ->
        Alcotest.fail "projection failure stopped instead of crashing"
    | _ when attempts = 0 ->
        Alcotest.fail "projection delivery failure did not settle"
    | _ -> await_closed (attempts - 1)
  in
  await_closed 20

let expect_projection_delivery_failure settlement =
  Alcotest.(check bool) "adapter-delivery origin" true
    (settlement.Crux.Failure.failure.primary.origin
    = Crux.Failure.Adapter_delivery);
  Alcotest.(check bool) "projection-delivery trigger" true
    (settlement.failure.primary.trigger
    = Crux.Failure.Projection_delivery)

let test_projection_encode_failure_key () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let key_codec =
    Crux.Codec.make
      ~encode:(fun (_ : int) ->
        Error { Crux.Codec.message = "private-key-encode-diagnostic" })
      ~decode:(fun _ -> Ok 1)
  in
  let projection =
    Harness.Keyed.create ~name:"encode.failure.key"
      ~key_compare:Int.compare ~key_codec ~value_codec:int_codec
      ~value_equal:Int.equal ~cutoff:Crux.Cutoff.never
  in
  let root =
    Crux.Root.create ~catalog:(Harness.Keyed.catalog projection)
      ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Harness.Keyed.publish projection ~key:1 (Crux.return 10))
  in
  let driver, _admin, peer = serialized_driver root in
  ignore (run_ok runtime (Crux.Driver.poll driver));
  Alcotest.(check bool) "commit survives key encode failure" true
    (Option.is_some (Crux.Driver.latest_committed_snapshot driver));
  Alcotest.(check bool) "no projection frame on key encode failure" true
    (run_ok runtime (Crux.Serialized_session.poll_outgoing peer) = None);
  let settlement =
    settle_serialized_crash
      ~forbidden:"private-key-encode-diagnostic" runtime driver peer
  in
  expect_projection_delivery_failure settlement

let test_projection_encode_failure_value () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let value_codec =
    Crux.Codec.make
      ~encode:(fun (_ : int) ->
        Error { Crux.Codec.message = "private-value-encode-diagnostic" })
      ~decode:(fun _ -> Ok 10)
  in
  let projection =
    Harness.create ~name:"encode.failure.value" ~codec:value_codec
      ~value_equal:Int.equal ~cutoff:Crux.Cutoff.never
  in
  let root =
    Harness.root projection ~projection_capacity:1 ~ingress_capacity:1
      ~request_capacity:1 (Crux.return 10)
  in
  let driver, _admin, peer = serialized_driver root in
  ignore (run_ok runtime (Crux.Driver.poll driver));
  Alcotest.(check bool) "commit survives value encode failure" true
    (Option.is_some (Crux.Driver.latest_committed_snapshot driver));
  Alcotest.(check bool) "no projection frame on value encode failure" true
    (run_ok runtime (Crux.Serialized_session.poll_outgoing peer) = None);
  let settlement =
    settle_serialized_crash
      ~forbidden:"private-value-encode-diagnostic" runtime driver peer
  in
  expect_projection_delivery_failure settlement

let test_projection_codec_raise_defect () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let sentinel = Failure "projection-codec-raise" in
  let value_codec =
    Crux.Codec.make
      ~encode:(fun (_ : int) -> raise sentinel)
      ~decode:(fun _ -> Ok 10)
  in
  let projection =
    Harness.create ~name:"encode.raise.value" ~codec:value_codec
      ~value_equal:Int.equal ~cutoff:Crux.Cutoff.never
  in
  let root =
    Harness.root projection ~projection_capacity:1 ~ingress_capacity:1
      ~request_capacity:1 (Crux.return 10)
  in
  let driver, _admin, peer = serialized_driver root in
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let settlement = settle_serialized_crash runtime driver peer in
  expect_projection_delivery_failure settlement;
  Alcotest.(check bool) "codec exception remained a defect" true
    (Format.asprintf "%a" Crux.Failure.Packed_cause.pp
       settlement.failure.primary.cause
    |> fun rendered ->
    contains_substring rendered "projection-codec-raise")

let wire_entry ?(key = 1) ?(incarnation = 1L) ?(value = 10) () =
  {
    Crux.Wire.Frame.kind = "adapter.atomic";
    key = Bytes.of_string (string_of_int key);
    incarnation;
    value = Bytes.of_string (string_of_int value);
  }

let test_projection_adapter_atomic_install () =
  let projection =
    Harness.Keyed.create ~name:"adapter.atomic"
      ~key_compare:Int.compare ~key_codec:int_codec
      ~value_codec:int_codec ~value_equal:Int.equal
      ~cutoff:Crux.Cutoff.never
  in
  let recipient = Recipient.create projection ~capacity:2 in
  let bootstrap =
    Crux.Wire.Frame.Projection_deliver
      {
        seq = 0l;
        reason = `Session_replacement;
        content = Bootstrap [ wire_entry () ];
      }
  in
  Alcotest.(check bool) "initial install" true
    (Recipient.apply recipient bootstrap = Ok ());
  Recipient.fail_next_install recipient;
  let changed =
    Crux.Wire.Frame.Projection_deliver
      {
        seq = 1l;
        reason = `Advancement;
        content =
          Updates
            [ Crux.Wire.Frame.Changed (wire_entry ~value:20 ()) ];
      }
  in
  Alcotest.(check bool) "injected install failed" true
    (Recipient.apply recipient changed = Error Recipient.Install_failed);
  Alcotest.(check (option int)) "prior state stayed observable" (Some 10)
    (Recipient.find_value recipient ~key:1)

let test_projection_identity_zero_codec () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let key_calls = ref 0 in
  let value_calls = ref 0 in
  let key_codec =
    Crux.Codec.make
      ~encode:(fun () ->
        incr key_calls;
        raise (Failure "identity key codec ran"))
      ~decode:(fun _ -> Error { Crux.Codec.message = "unused" })
  in
  let value_codec =
    Crux.Codec.make
      ~encode:(fun (_ : int) ->
        incr value_calls;
        raise (Failure "identity value codec ran"))
      ~decode:(fun _ -> Error { Crux.Codec.message = "unused" })
  in
  let kind =
    Crux.Projection.Kind.define ~name:"identity.zero-codec"
      ~key_compare:Unit.compare ~key_codec ~value_codec
      ~value_equal:Int.equal ~cutoff:Crux.Cutoff.never
  in
  let root =
    Crux.Root.create
      ~catalog:
        (Crux.Projection.Catalog.create
           [ Crux.Projection.Kind.Pack kind ])
      ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
      (Crux.Projection.publish kind ~key:() (Crux.return 10))
  in
  let driver =
    Crux.Driver.create (Crux.Driver.Binding.identity []) root
  in
  let delivery =
    match run_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "identity delivery missing"
  in
  ignore (run_ok runtime (Crux.Driver.Delivery.delivered delivery));
  Alcotest.(check int) "identity key codec calls" 0 !key_calls;
  Alcotest.(check int) "identity value codec calls" 0 !value_calls

let test_projection_value_handle_fence () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let selector_endpoint = ref None in
  let stale_export = ref None in
  let selector =
    Crux.State_machine.create (Crux.return ()) ~default_model:true
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        (action, None))
  in
  let selected =
    Crux.map selector ~f:(fun (active, endpoint) ->
        selector_endpoint := Some endpoint;
        active)
  in
  let target =
    Crux.State_machine.create (Crux.return ()) ~default_model:()
      ~apply_action:(fun ~self:_ ~input:() ~model:() ~action:() ->
        ((), None))
  in
  let exported =
    Crux.Exported_endpoint.create (Crux.map target ~f:snd)
      ~codec:unit_codec
  in
  let projected =
    Crux.bind selected ~f:(fun active ->
        if active then
          Crux.map exported ~f:(fun export ->
              stale_export := Some export;
              export)
        else Crux.return (Option.get !stale_export))
  in
  let value_codec =
    Crux.Codec.make
      ~encode:(fun export ->
        Ok (Crux.Exported_endpoint.remote_handle export))
      ~decode:(fun _ ->
        Error { Crux.Codec.message = "handle projection is encode-only" })
  in
  let projection =
    Harness.create ~name:"value.handle-fence" ~codec:value_codec
      ~value_equal:( == ) ~cutoff:Crux.Cutoff.never
  in
  let root =
    Harness.root projection ~projection_capacity:1 ~ingress_capacity:2
      ~request_capacity:1 projected
  in
  let driver, _admin, peer = serialized_driver root in
  acknowledge_projection runtime driver peer;
  ignore
    (run_ok runtime
       (Crux.Endpoint.send (Option.get !selector_endpoint) false
       |> Eta.Effect.or_die (fun Crux.Endpoint.Ingress_closed ->
              Failure "selector closed")));
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let settlement =
    settle_serialized_crash ~result_seq:1l runtime driver peer
  in
  expect_projection_delivery_failure settlement;
  let rendered =
    Format.asprintf "%a" Crux.Failure.Packed_cause.pp
      settlement.failure.primary.cause
  in
  if not (contains_substring rendered "remote") then
    Alcotest.failf "missing export cause was not retained: %s" rendered

let test_projection_push_frame_too_large () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let projection =
    Harness.create ~name:"frame.too-large"
      ~codec:
        (Crux.Codec.make
           ~encode:(fun value -> Ok (Bytes.of_string value))
           ~decode:(fun bytes -> Ok (Bytes.to_string bytes)))
      ~value_equal:String.equal ~cutoff:Crux.Cutoff.never
  in
  let root =
    Harness.root projection ~projection_capacity:1 ~ingress_capacity:1
      ~request_capacity:1 (Crux.return (String.make 2_048 'x'))
  in
  let driver, _admin, peer =
    serialized_driver ~max_frame_bytes:128 root
  in
  ignore (run_ok runtime (Crux.Driver.poll driver));
  let rec await_closed attempts =
    match run_ok runtime (Crux.Driver.poll driver) with
    | Some (Crux.Driver.Closed (Crux.Driver.Crashed settlement)) ->
        settlement
    | _ when attempts = 0 ->
        Alcotest.fail "oversize projection did not close and crash"
    | _ -> await_closed (attempts - 1)
  in
  let settlement = await_closed 20 in
  expect_projection_delivery_failure settlement;
  Alcotest.(check bool) "oversize session closed" true
    (match
       receive runtime peer
         (Crux.Wire.Frame.Request_cancel
            { seq = 0l; request = Bytes.empty })
     with
    | Error Crux.Serialized_session.Session_closed -> true
    | _ -> false)

let () =
  Alcotest.run "eta_crux projection wire"
    [
      ( "projection",
        [
          Alcotest.test_case "key encode failure" `Quick
            test_projection_encode_failure_key;
          Alcotest.test_case "value encode failure" `Quick
            test_projection_encode_failure_value;
          Alcotest.test_case "codec raise defect" `Quick
            test_projection_codec_raise_defect;
          Alcotest.test_case "adapter atomic install" `Quick
            test_projection_adapter_atomic_install;
          Alcotest.test_case "identity zero codec" `Quick
            test_projection_identity_zero_codec;
          Alcotest.test_case "value handle fence" `Quick
            test_projection_value_handle_fence;
          Alcotest.test_case "push frame too large" `Quick
            test_projection_push_frame_too_large;
        ] );
    ]
