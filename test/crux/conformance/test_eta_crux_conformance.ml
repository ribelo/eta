module Crux = Eta_crux

let run_ok eff =
  Eta_test.Run.run eff |> fun result ->
  Eta_test.Expect.expect_ok result.exit

let committed = function
  | Ok (Crux.Root.Committed { output; post_commit }) ->
      (output, post_commit)
  | _ -> Alcotest.fail "expected committed advancement"

let conformance_identity_zero_wire () =
  let codec =
    Crux.Codec.make
      ~encode:(fun _ -> Alcotest.fail "identity path encoded payload")
      ~decode:(fun _ -> Alcotest.fail "identity path decoded payload")
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, Eta.Effect.unit))
  in
  let description =
    Crux.both machine
      (Crux.Exported_endpoint.create (Crux.map machine ~f:snd)
         ~codec)
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 description
  in
  let ((_, _), export), initial_post =
    committed (run_ok (Crux.Root.advance root))
  in
  ignore (run_ok (Crux.Post_commit.start initial_post));
  Alcotest.(check bool) "local invocation accepted" true
    (Crux.Exported_endpoint.try_invoke export 7 = Ok (Ok (Ok ())));
  let ((model, _), _), action_post =
    committed (run_ok (Crux.Root.advance root))
  in
  Alcotest.(check int) "local typed payload" 7 model;
  ignore (run_ok (Crux.Post_commit.start action_post));
  Crux.Root.request_stop root;
  let stop_post =
    match run_ok (Crux.Root.advance root) with
    | Ok (Crux.Root.Stopped { post_commit }) -> post_commit
    | _ -> Alcotest.fail "root did not stop"
  in
  ignore (run_ok (Crux.Post_commit.start stop_post))

let int_codec =
  Crux.Codec.make
    ~encode:(fun value -> Bytes.of_string (string_of_int value))
    ~decode:(fun bytes ->
      match int_of_string_opt (Bytes.to_string bytes) with
      | Some value -> Ok value
      | None -> Error { Crux.Codec.message = "invalid integer" })

let conformance_identity_serialized_equivalence () =
  let identity_root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return 7)
  in
  let identity_driver =
    Crux.Driver.create
      (Crux.Driver.Binding.identity [])
      identity_root
  in
  let identity_delivery =
    match run_ok (Crux.Driver.poll identity_driver) with
    | Some (Crux.Driver.Deliver delivery) -> delivery
    | _ -> Alcotest.fail "identity binding did not deliver output"
  in
  let identity_output =
    Crux.Driver.Delivery.output identity_delivery
  in
  ignore
    (run_ok
       (Crux.Driver.Delivery.delivered identity_delivery));
  Crux.Driver.request_stop identity_driver;
  let identity_terminal =
    match run_ok (Crux.Driver.poll identity_driver) with
    | Some (Crux.Driver.Closed terminal) -> terminal
    | _ -> Alcotest.fail "identity binding did not close"
  in

  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let serialized_binding, _admin =
    Crux.Driver.Binding.serialized ~output:int_codec ~operations:[]
      ~session:candidate
  in
  let serialized_root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return 7)
  in
  let serialized_driver =
    Crux.Driver.create serialized_binding serialized_root
  in
  Alcotest.(check bool) "serialized delivery is transport-owned" true
    (run_ok (Crux.Driver.poll serialized_driver) = None);
  let outgoing =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> bytes
    | None -> Alcotest.fail "serialized binding emitted no output frame"
  in
  let sequence, serialized_output =
    match Eta_crux_json.Format.decode outgoing with
    | Ok
        (Crux.Wire.Frame.Output_deliver
          {
            seq;
            reason = `Advancement;
            output;
          }) ->
        let output =
          match Crux.Codec.decode int_codec output with
          | Ok value -> value
          | Error _ -> Alcotest.fail "serialized output payload did not decode"
        in
        (seq, output)
    | Ok _ -> Alcotest.fail "serialized binding emitted wrong frame family"
    | Error _ -> Alcotest.fail "serialized output envelope did not decode"
  in
  let response =
    Crux.Wire.Frame.Output_result
      {
        seq = 0l;
        reply_to = sequence;
        result = `Accepted;
      }
    |> Eta_crux_json.Format.encode
  in
  Alcotest.(check bool) "serialized acknowledgment accepted" true
    (run_ok (Crux.Serialized_session.receive peer response) = Ok ());
  Alcotest.(check bool) "serialized acknowledgment removes fence" true
    (run_ok (Crux.Driver.poll serialized_driver) = None);
  Crux.Driver.request_stop serialized_driver;
  let serialized_terminal =
    match run_ok (Crux.Driver.poll serialized_driver) with
    | Some (Crux.Driver.Closed terminal) -> terminal
    | _ -> Alcotest.fail "serialized binding did not close"
  in
  Alcotest.(check int) "same typed output" identity_output
    serialized_output;
  Alcotest.(check bool) "same terminal outcome" true
    (identity_terminal = serialized_terminal);

  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        (model + action, Eta.Effect.unit))
  in
  let export =
    Crux.Exported_endpoint.create
      (Crux.map machine ~f:snd)
      ~codec:int_codec
  in
  let description = Crux.both machine export in
  let exported_output_codec =
    Crux.Codec.make
      ~encode:(fun ((model, _endpoint), export) ->
        let handle =
          Crux.Exported_endpoint.remote_handle export
        in
        let bytes = Bytes.create (4 + Bytes.length handle) in
        Bytes.set_int32_be bytes 0 (Int32.of_int model);
        Bytes.blit handle 0 bytes 4 (Bytes.length handle);
        bytes)
      ~decode:(fun _ ->
        Error
          {
            Crux.Codec.message =
              "test output codec is encode-only";
          })
  in
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let binding, _admin =
    Crux.Driver.Binding.serialized ~output:exported_output_codec
      ~operations:[] ~session:candidate
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      description
  in
  let driver = Crux.Driver.create binding root in
  ignore (run_ok (Crux.Driver.poll driver));
  let initial_output_sequence, handle =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Output_deliver
              { seq; output; _ }) ->
            Alcotest.(check int32) "initial exported model" 0l
              (Bytes.get_int32_be output 0);
            (seq, Bytes.sub output 4 (Bytes.length output - 4))
        | Ok _ | Error _ ->
            Alcotest.fail "serialized export output malformed")
    | None -> Alcotest.fail "serialized export output missing"
  in
  let acknowledge_initial =
    Crux.Wire.Frame.Output_result
      {
        seq = 0l;
        reply_to = initial_output_sequence;
        result = `Accepted;
      }
    |> Eta_crux_json.Format.encode
  in
  ignore
    (run_ok
       (Crux.Serialized_session.receive peer acknowledge_initial));
  ignore (run_ok (Crux.Driver.poll driver));
  let invocation =
    Crux.Wire.Frame.Endpoint_invoke
      {
        seq = 1l;
        handle;
        payload = Crux.Codec.encode int_codec 11;
      }
    |> Eta_crux_json.Format.encode
  in
  ignore
    (run_ok (Crux.Serialized_session.receive peer invocation));
  ignore (run_ok (Crux.Driver.poll driver));
  let invocation_result =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Endpoint_result
              { result = `Accepted; _ }) ->
            true
        | Ok _ | Error _ -> false)
    | None -> false
  in
  Alcotest.(check bool) "remote endpoint accepted" true
    invocation_result;
  ignore (run_ok (Crux.Driver.poll driver));
  let committed_sequence, committed_model =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Output_deliver
              { seq; output; _ }) ->
            (seq, Int32.to_int (Bytes.get_int32_be output 0))
        | Ok _ | Error _ ->
            Alcotest.fail "serialized endpoint commit malformed")
    | None ->
        Alcotest.fail "serialized endpoint did not commit"
  in
  Alcotest.(check int) "serialized endpoint typed action" 11
    committed_model;
  let acknowledge_commit =
    Crux.Wire.Frame.Output_result
      {
        seq = 2l;
        reply_to = committed_sequence;
        result = `Accepted;
      }
    |> Eta_crux_json.Format.encode
  in
  ignore
    (run_ok
       (Crux.Serialized_session.receive peer acknowledge_commit));
  ignore (run_ok (Crux.Driver.poll driver));
  Crux.Driver.request_stop driver;
  ignore (run_ok (Crux.Driver.poll driver))

let test_session_loss_requests () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let run_ok eff =
    Eta.Runtime.run runtime eff
    |> Eta_test.Expect.expect_ok
  in
  let operation =
    Crux.Host_operation.define ~name:"test.session-loss"
      ~request:int_codec ~response:int_codec
  in
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let unit_codec =
    Crux.Codec.make ~encode:(fun () -> Bytes.empty)
      ~decode:(fun bytes ->
        if Bytes.length bytes = 0 then Ok ()
        else Error { Crux.Codec.message = "expected empty payload" })
  in
  let binding, _admin =
    Crux.Driver.Binding.serialized ~output:unit_codec
      ~operations:[ Crux.Host_operation.Pack operation ]
      ~session:candidate
  in
  let requester =
    Crux.Driver.Binding.requester binding operation
  in
  let request_result = ref None in
  let request_program =
    Crux.Requester.request requester 7
    |> Eta.Effect.to_result
    |> Eta.Effect.map (fun result ->
           request_result := Some result)
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.lifecycle (Crux.return request_program))
  in
  let driver = Crux.Driver.create binding root in
  ignore (run_ok (Crux.Driver.poll driver));
  let output_frame =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok (Crux.Wire.Frame.Output_deliver { seq; _ }) -> seq
        | Ok _ | Error _ ->
            Alcotest.fail "session-loss output frame malformed")
    | None -> Alcotest.fail "session-loss output was not emitted"
  in
  let output_reply =
    Crux.Wire.Frame.Output_result
      {
        seq = 0l;
        reply_to = output_frame;
        result = `Accepted;
      }
    |> Eta_crux_json.Format.encode
  in
  ignore
    (run_ok
       (Crux.Serialized_session.receive peer output_reply));
  ignore (run_ok (Crux.Driver.poll driver));
  let rec await_dispatch attempts =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Request_dispatch
              { request; operation = "test.session-loss"; _ }) ->
            request
        | Ok _ | Error _ ->
            Alcotest.fail "session-loss request frame malformed")
    | None when attempts = 0 ->
        Alcotest.fail "outbound request was not serialized"
    | None ->
        ignore (run_ok (Crux.Driver.poll driver));
        Eio.Fiber.yield ();
        await_dispatch (attempts - 1)
  in
  let request_token = await_dispatch 100 in
  Alcotest.(check bool) "bounded request token" true
    (Bytes.length request_token <= 64);
  Alcotest.(check bool) "malformed frame closes session" true
    (Result.is_error
       (run_ok
          (Crux.Serialized_session.receive peer
             (Bytes.of_string "{}"))));
  ignore (run_ok (Crux.Driver.poll driver));
  let rec await_closed_request attempts =
    match !request_result with
    | Some result -> result
    | None when attempts = 0 ->
        Alcotest.fail "session loss did not close request"
    | None ->
        Eio.Fiber.yield ();
        await_closed_request (attempts - 1)
  in
  Alcotest.(check bool) "exact session closure reason" true
    (await_closed_request 100
    = Error
        (Crux.Requester.Closed Crux.Request.Session_closed));
  Crux.Driver.request_stop driver;
  (match run_ok (Crux.Driver.poll driver) with
  | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
  | _ -> Alcotest.fail "session loss crashed or stranded root")

let test_serialized_receive_wakes_await () =
  Eta_test.with_test_clock @@ fun switch clock runtime ->
  let run_ok eff =
    Eta.Runtime.run runtime eff
    |> Eta_test.Expect.expect_ok
  in
  let started = Eta.Promise.create () in
  let program =
    Eta.Promise.resolve started (Eta.Exit.Ok ())
    |> Eta.Effect.map (fun _ -> ())
  in
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let unit_codec =
    Crux.Codec.make ~encode:(fun () -> Bytes.empty)
      ~decode:(fun _ -> Ok ())
  in
  let binding, _admin =
    Crux.Driver.Binding.serialized ~output:unit_codec
      ~operations:[] ~session:candidate
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.lifecycle (Crux.return program))
  in
  let driver = Crux.Driver.create binding root in
  let driver_waiter =
    Eta_test.Async.fork_run switch runtime
      (Crux.Driver.await driver)
  in
  let rec await_output attempts =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok (Crux.Wire.Frame.Output_deliver { seq; _ }) -> seq
        | Ok _ | Error _ ->
            Alcotest.fail "serialized await output malformed")
    | None when attempts = 0 ->
        Alcotest.fail "serialized await emitted no output"
    | None ->
        Eio.Fiber.yield ();
        await_output (attempts - 1)
  in
  let output_sequence = await_output 100 in
  let acknowledgment =
    Crux.Wire.Frame.Output_result
      {
        seq = 0l;
        reply_to = output_sequence;
        result = `Accepted;
      }
    |> Eta_crux_json.Format.encode
  in
  ignore
    (run_ok
       (Crux.Serialized_session.receive peer acknowledgment));
  let started_waiter =
    Eta_test.Async.fork_run switch runtime
      (Eta.Promise.await started
      |> Eta.Effect.timeout_as (Eta.Duration.ms 1)
           ~on_timeout:`Timeout
      |> Eta.Effect.or_die (fun `Timeout ->
             Failure
               "serialized receive did not wake Driver.await"))
  in
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done;
  if not (Eio.Promise.is_resolved started_waiter) then
    Eta_test.Test_clock.adjust clock (Eta.Duration.ms 1);
  (match Eta_test.Async.await started_waiter with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "serialized start waiter failed: %a"
        (Eta.Cause.pp (fun _ (value : Crux.never) ->
             match value with _ -> .))
        cause);
  Crux.Driver.request_stop driver;
  (match Eta_test.Async.await driver_waiter with
  | Eta.Exit.Ok (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
  | Eta.Exit.Ok _ ->
      Alcotest.fail "serialized await did not stop"
  | Eta.Exit.Error cause ->
      Alcotest.failf "serialized driver waiter failed: %a"
        (Eta.Cause.pp (fun _ (value : Crux.never) ->
             match value with _ -> .))
        cause)

let test_session_loss_settles_pending_delivery () =
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let binding, _admin =
    Crux.Driver.Binding.serialized ~output:int_codec
      ~operations:[] ~session:candidate
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return 17)
  in
  let driver = Crux.Driver.create binding root in
  Alcotest.(check bool) "delivery is transport-owned" true
    (run_ok (Crux.Driver.poll driver) = None);
  Alcotest.(check bool) "malformed frame closes session" true
    (Result.is_error
       (run_ok
          (Crux.Serialized_session.receive peer
             (Bytes.of_string "{}"))));
  let rec await_closed attempts =
    match run_ok (Crux.Driver.poll driver) with
    | Some
        (Crux.Driver.Closed
          (Crux.Driver.Crashed settlement)) ->
        settlement
    | Some _ ->
        Alcotest.fail
          "session loss emitted a nonterminal event"
    | None when attempts = 0 ->
        Alcotest.fail
          "session loss stranded pending output delivery"
    | None -> await_closed (attempts - 1)
  in
  let settlement = await_closed 5 in
  Alcotest.(check bool) "adapter delivery failure origin" true
    (settlement.failure.primary.origin
    = Crux.Failure.Adapter_delivery);
  Alcotest.(check bool) "delivery failure trigger" true
    (settlement.failure.primary.trigger
    = Crux.Failure.Output_delivery)

let test_session_loss_settles_replacement () =
  Eta_test.with_test_clock @@ fun switch _clock runtime ->
  let run_ok eff =
    Eta.Runtime.run runtime eff
    |> Eta_test.Expect.expect_ok
  in
  let old_candidate, old_peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let binding, admin =
    Crux.Driver.Binding.serialized ~output:int_codec
      ~operations:[] ~session:old_candidate
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.return 23)
  in
  let driver = Crux.Driver.create binding root in
  ignore (run_ok (Crux.Driver.poll driver));
  let initial_sequence =
    match run_ok (Crux.Serialized_session.poll_outgoing old_peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok (Crux.Wire.Frame.Output_deliver { seq; _ }) -> seq
        | Ok _ | Error _ ->
            Alcotest.fail "replacement-loss initial output malformed")
    | None ->
        Alcotest.fail "replacement-loss initial output missing"
  in
  ignore
    (run_ok
       (Crux.Serialized_session.receive old_peer
          (Eta_crux_json.Format.encode
             (Crux.Wire.Frame.Output_result
                {
                  seq = 0l;
                  reply_to = initial_sequence;
                  result = `Accepted;
                }))));
  ignore (run_ok (Crux.Driver.poll driver));
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let replacement =
    Eta_test.Async.fork_run switch runtime
      (Crux.Serialized_session.replace admin candidate
      |> Eta.Effect.or_die (fun _ ->
             Failure "replacement unexpectedly rejected"))
  in
  let rec await_replacement_output attempts =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Output_deliver
              { reason = `Session_replacement; _ }) ->
            ()
        | Ok _ | Error _ ->
            Alcotest.fail "replacement-loss output malformed")
    | None when attempts = 0 ->
        Alcotest.fail "replacement-loss output missing"
    | None ->
        Eio.Fiber.yield ();
        await_replacement_output (attempts - 1)
  in
  await_replacement_output 100;
  Alcotest.(check bool) "replacement session closed" true
    (Result.is_error
       (run_ok
          (Crux.Serialized_session.receive peer
             (Bytes.of_string "{}"))));
  ignore (run_ok (Crux.Driver.poll driver));
  (match Eta_test.Async.await replacement with
  | Eta.Exit.Ok (Crux.Serialized_session.Crashed failure) ->
      Alcotest.(check bool) "replacement failure origin" true
        (failure.primary.origin
        = Crux.Failure.Adapter_delivery)
  | Eta.Exit.Ok _ ->
      Alcotest.fail "closed replacement reported success"
  | Eta.Exit.Error cause ->
      Alcotest.failf "replacement waiter failed: %a"
        (Eta.Cause.pp (fun _ (value : Crux.never) ->
             match value with _ -> .))
        cause);
  (match run_ok (Crux.Driver.poll driver) with
  | Some
      (Crux.Driver.Closed
        (Crux.Driver.Crashed { teardown_settled = true; _ })) ->
      ()
  | _ -> Alcotest.fail "closed replacement stranded driver")

let test_raising_response_decoder_is_fatal () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let run_ok eff =
    Eta.Runtime.run runtime eff
    |> Eta_test.Expect.expect_ok
  in
  let response_codec =
    Crux.Codec.make ~encode:(fun value ->
        Bytes.of_string (string_of_int value))
      ~decode:(fun _ ->
        raise (Failure "response decoder sentinel"))
  in
  let operation =
    Crux.Host_operation.define
      ~name:"test.raising-response-decoder"
      ~request:int_codec ~response:response_codec
  in
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:2048
      ~format:(module Eta_crux_json.Format)
  in
  let unit_codec =
    Crux.Codec.make ~encode:(fun () -> Bytes.empty)
      ~decode:(fun _ -> Ok ())
  in
  let binding, _admin =
    Crux.Driver.Binding.serialized ~output:unit_codec
      ~operations:[ Crux.Host_operation.Pack operation ]
      ~session:candidate
  in
  let requester =
    Crux.Driver.Binding.requester binding operation
  in
  let request_result = ref None in
  let request_program =
    Crux.Requester.request requester 7
    |> Eta.Effect.to_result
    |> Eta.Effect.map (fun result ->
           request_result := Some result)
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      (Crux.lifecycle (Crux.return request_program))
  in
  let driver = Crux.Driver.create binding root in
  ignore (run_ok (Crux.Driver.poll driver));
  let output_sequence =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok (Crux.Wire.Frame.Output_deliver { seq; _ }) -> seq
        | Ok _ | Error _ ->
            Alcotest.fail "decoder test output malformed")
    | None -> Alcotest.fail "decoder test output missing"
  in
  ignore
    (run_ok
       (Crux.Serialized_session.receive peer
          (Eta_crux_json.Format.encode
             (Crux.Wire.Frame.Output_result
                {
                  seq = 0l;
                  reply_to = output_sequence;
                  result = `Accepted;
                }))));
  ignore (run_ok (Crux.Driver.poll driver));
  let rec await_dispatch attempts =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Request_dispatch
              { seq; request; _ }) ->
            (seq, request)
        | Ok _ | Error _ ->
            Alcotest.fail "decoder test dispatch malformed")
    | None when attempts = 0 ->
        Alcotest.fail "decoder test dispatch missing"
    | None ->
        ignore (run_ok (Crux.Driver.poll driver));
        Eio.Fiber.yield ();
        await_dispatch (attempts - 1)
  in
  let dispatch_sequence, request = await_dispatch 100 in
  ignore
    (run_ok
       (Crux.Serialized_session.receive peer
          (Eta_crux_json.Format.encode
             (Crux.Wire.Frame.Request_dispatch_result
                {
                  seq = 1l;
                  reply_to = dispatch_sequence;
                  accepted = true;
                }))));
  ignore (run_ok (Crux.Driver.poll driver));
  ignore
    (run_ok
       (Crux.Serialized_session.receive peer
          (Eta_crux_json.Format.encode
             (Crux.Wire.Frame.Request_resolved
                {
                  seq = 2l;
                  request;
                  payload = Bytes.of_string "not decoded";
                }))));
  ignore (run_ok (Crux.Driver.poll driver));
  let crash_sequence, failure =
    let rec await_crash attempts =
      match run_ok (Crux.Serialized_session.poll_outgoing peer) with
      | Some bytes -> (
          match Eta_crux_json.Format.decode bytes with
          | Ok
              (Crux.Wire.Frame.Crash_notify
                { seq; failure }) ->
              (seq, failure)
          | Ok _ | Error _ ->
              Alcotest.fail "decoder crash frame malformed")
      | None when attempts = 0 ->
          Alcotest.fail "raising decoder did not crash root"
      | None ->
          ignore (run_ok (Crux.Driver.poll driver));
          Eio.Fiber.yield ();
          await_crash (attempts - 1)
    in
    await_crash 100
  in
  Alcotest.(check bool) "inbound response trigger" true
    (failure.primary.trigger
    = Crux.Failure.Inbound_response);
  Alcotest.(check bool) "request dispatch origin" true
    (failure.primary.origin
    = Crux.Failure.Request_dispatch);
  ignore
    (run_ok
       (Crux.Serialized_session.receive peer
          (Eta_crux_json.Format.encode
             (Crux.Wire.Frame.Crash_result
                {
                  seq = 3l;
                  reply_to = crash_sequence;
                  result = `Accepted;
                }))));
  ignore (run_ok (Crux.Driver.poll driver));
  (match run_ok (Crux.Driver.poll driver) with
  | Some
      (Crux.Driver.Closed
        (Crux.Driver.Crashed { teardown_settled = true; _ })) ->
      ()
  | _ -> Alcotest.fail "raising decoder crash did not settle");
  Alcotest.(check bool) "request completed once" true
    (Option.is_some !request_result)

let conformance_serialized_request_export () =
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  let run_ok eff =
    Eta.Runtime.run runtime eff
    |> Eta_test.Expect.expect_ok
  in
  let machine =
    Crux.State_machine.create (Crux.return ()) ~default_model:0
      ~apply_action:
        (fun ~self:_ ~input:() ~model:_
             ~action:(request, responder) ->
          ( request,
            Crux.Responder.resolve responder (request * 2)
            |> Eta.Effect.ignore_errors ))
  in
  let export =
    Crux.Request_export.create
      (Crux.map machine ~f:snd)
      ~request:int_codec ~response:int_codec
  in
  let output_codec =
    Crux.Codec.make
      ~encode:Crux.Request_export.remote_handle
      ~decode:(fun _ ->
        Error
          {
            Crux.Codec.message =
              "request export output is encode-only";
          })
  in
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:1024
      ~format:(module Eta_crux_json.Format)
  in
  let binding, _admin =
    Crux.Driver.Binding.serialized ~output:output_codec
      ~operations:[] ~session:candidate
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      export
  in
  let driver = Crux.Driver.create binding root in
  ignore (run_ok (Crux.Driver.poll driver));
  let initial_sequence, handle =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Output_deliver
              { seq; output; _ }) ->
            (seq, output)
        | Ok _ | Error _ ->
            Alcotest.fail "request export output malformed")
    | None -> Alcotest.fail "request export output missing"
  in
  let initial_reply =
    Crux.Wire.Frame.Output_result
      {
        seq = 0l;
        reply_to = initial_sequence;
        result = `Accepted;
      }
    |> Eta_crux_json.Format.encode
  in
  ignore
    (run_ok
       (Crux.Serialized_session.receive peer initial_reply));
  ignore (run_ok (Crux.Driver.poll driver));
  let start =
    Crux.Wire.Frame.Request_start
      {
        seq = 1l;
        handle;
        payload = Crux.Codec.encode int_codec 21;
      }
    |> Eta_crux_json.Format.encode
  in
  ignore
    (run_ok (Crux.Serialized_session.receive peer start));
  ignore (run_ok (Crux.Driver.poll driver));
  let request_token =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Request_start_result
              { result = `Started token; _ }) ->
            token
        | Ok _ | Error _ ->
            Alcotest.fail "request export did not start")
    | None -> Alcotest.fail "request start result missing"
  in
  ignore (run_ok (Crux.Driver.poll driver));
  let commit_sequence =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok (Crux.Wire.Frame.Output_deliver { seq; _ }) -> seq
        | Ok _ | Error _ ->
            Alcotest.fail "request export commit malformed")
    | None -> Alcotest.fail "request export did not commit"
  in
  let commit_reply =
    Crux.Wire.Frame.Output_result
      {
        seq = 2l;
        reply_to = commit_sequence;
        result = `Accepted;
      }
    |> Eta_crux_json.Format.encode
  in
  ignore
    (run_ok
       (Crux.Serialized_session.receive peer commit_reply));
  ignore (run_ok (Crux.Driver.poll driver));
  let rec await_resolution attempts =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Request_resolve
              { seq; request; payload }) ->
            (seq, request, payload)
        | Ok _ | Error _ ->
            Alcotest.fail "request resolution malformed")
    | None when attempts = 0 ->
        Alcotest.fail "request resolution missing"
    | None ->
        Eio.Fiber.yield ();
        await_resolution (attempts - 1)
  in
  let resolve_sequence, resolved_token, payload =
    await_resolution 100
  in
  Alcotest.(check bytes) "same request token" request_token
    resolved_token;
  let response =
    match Crux.Codec.decode int_codec payload with
    | Ok response -> response
    | Error _ -> Alcotest.fail "request response did not decode"
  in
  Alcotest.(check int) "typed request response" 42 response;
  let resolve_reply =
    Crux.Wire.Frame.Request_resolve_result
      {
        seq = 3l;
        reply_to = resolve_sequence;
        result = `Identity `Accepted;
      }
    |> Eta_crux_json.Format.encode
  in
  ignore
    (run_ok
       (Crux.Serialized_session.receive peer resolve_reply));
  ignore (run_ok (Crux.Driver.poll driver));
  Crux.Driver.request_stop driver;
  (match run_ok (Crux.Driver.poll driver) with
  | Some (Crux.Driver.Closed Crux.Driver.Stopped) -> ()
  | _ -> Alcotest.fail "request export driver did not stop")

let conformance_serialized_crash () =
  let description =
    Crux.map (Crux.return ()) ~f:(fun () ->
        raise (Failure "serialized-crash-sentinel"))
  in
  let unit_codec =
    Crux.Codec.make ~encode:(fun () -> Bytes.empty)
      ~decode:(fun bytes ->
        if Bytes.length bytes = 0 then Ok ()
        else
          Error
            { Crux.Codec.message = "expected empty payload" })
  in
  let candidate, peer =
    Crux.Serialized_session.candidate ~max_frame_bytes:2048
      ~format:(module Eta_crux_json.Format)
  in
  let binding, _admin =
    Crux.Driver.Binding.serialized ~output:unit_codec
      ~operations:[] ~session:candidate
  in
  let root =
    Crux.Root.create ~ingress_capacity:1 ~request_capacity:1
      description
  in
  let driver = Crux.Driver.create binding root in
  Alcotest.(check bool) "serialized crash is transport-owned" true
    (run_ok (Crux.Driver.poll driver) = None);
  let crash_sequence, remote_failure =
    match run_ok (Crux.Serialized_session.poll_outgoing peer) with
    | Some bytes -> (
        match Eta_crux_json.Format.decode bytes with
        | Ok
            (Crux.Wire.Frame.Crash_notify
              { seq; failure }) ->
            (seq, failure)
        | Ok _ | Error _ ->
            Alcotest.fail "serialized crash notification malformed")
    | None -> Alcotest.fail "serialized crash notification missing"
  in
  let reply =
    Crux.Wire.Frame.Crash_result
      {
        seq = 0l;
        reply_to = crash_sequence;
        result = `Accepted;
      }
    |> Eta_crux_json.Format.encode
  in
  ignore
    (run_ok (Crux.Serialized_session.receive peer reply));
  Alcotest.(check bool) "crash acknowledgment is internal" true
    (run_ok (Crux.Driver.poll driver) = None);
  let settlement =
    match run_ok (Crux.Driver.poll driver) with
  | Some
      (Crux.Driver.Closed
        (Crux.Driver.Crashed
          ({ teardown_settled = true; _ } as settlement))) ->
      settlement
  | _ -> Alcotest.fail "serialized crash did not settle"
  in
  Alcotest.(check bool) "portable crash is preserved" true
    (Crux.Failure.portable settlement.failure = remote_failure)

let () =
  Alcotest.run "eta_crux conformance"
    [
      ( "identity",
        [
          Alcotest.test_case "zero wire" `Quick
            conformance_identity_zero_wire;
          Alcotest.test_case "identity serialized equivalence" `Quick
            conformance_identity_serialized_equivalence;
          Alcotest.test_case "session loss requests" `Quick
            test_session_loss_requests;
          Alcotest.test_case "serialized receive wakes await" `Quick
            test_serialized_receive_wakes_await;
          Alcotest.test_case "session loss settles delivery" `Quick
            test_session_loss_settles_pending_delivery;
          Alcotest.test_case "session loss settles replacement" `Quick
            test_session_loss_settles_replacement;
          Alcotest.test_case "raising response decoder" `Quick
            test_raising_response_decoder_is_fatal;
          Alcotest.test_case "serialized request export" `Quick
            conformance_serialized_request_export;
          Alcotest.test_case "serialized crash" `Quick
            conformance_serialized_crash;
        ] );
    ]
