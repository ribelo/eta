module Frame = Eta_crux.Wire.Frame

let portable_failure : Eta_crux.Failure.portable =
  {
    primary =
      {
        cause =
          Eta.Cause.Portable.Sequential
            [
              Fail "typed";
              Interrupt
                (Some (Eta.Cause.fresh_interrupt_id ()));
            ];
        origin = Eta_crux.Failure.Graph_clock;
        trigger = Eta_crux.Failure.Clock_sample;
        position = 17L;
      };
    secondary =
      [
        {
          cause =
            Eta.Cause.Portable.Die
              {
                kind = "Failure";
                message = "secondary";
                backtrace = Some "trace";
                span_name = Some "span";
                annotations = [ ("key", "value") ];
              };
          origin = Eta_crux.Failure.Cleanup;
          trigger = Eta_crux.Failure.Crash_teardown;
          position = 18L;
        };
        {
          cause = Eta.Cause.Portable.Fail "clock due";
          origin = Eta_crux.Failure.Transition;
          trigger = Eta_crux.Failure.Clock_due;
          position = 19L;
        };
        {
          cause = Eta.Cause.Portable.Fail "reset";
          origin = Eta_crux.Failure.Transition;
          trigger = Eta_crux.Failure.Structural_reset;
          position = 20L;
        };
        {
          cause = Eta.Cause.Portable.Fail "poll";
          origin = Eta_crux.Failure.Owned_work;
          trigger = Eta_crux.Failure.Poll_effect;
          position = 21L;
        };
        {
          cause = Eta.Cause.Portable.Fail "action";
          origin = Eta_crux.Failure.Transition;
          trigger = Eta_crux.Failure.Endpoint_action;
          position = 22L;
        };
      ];
  }

let frames =
  [
    Frame.Projection_deliver
      {
        seq = 0l;
        reason = `Advancement;
        content =
          Updates
            [
              Attached
                {
                  kind = "counter";
                  key = Bytes.empty;
                  incarnation = 1L;
                  value = Bytes.of_string "out";
                };
            ];
      };
    Projection_result { seq = 1l; reply_to = 0l; result = `Accepted };
    Crash_notify { seq = 2l; failure = portable_failure };
    Crash_result
      { seq = 2l; reply_to = 1l; result = `Failed "adapter" };
    Endpoint_invoke
      {
        seq = 3l;
        handle = Bytes.of_string "handle";
        payload = Bytes.of_string "payload";
      };
    Endpoint_result { seq = 4l; reply_to = 3l; result = `Full };
    Request_start
      {
        seq = 5l;
        handle = Bytes.of_string "request-export";
        payload = Bytes.empty;
      };
    Request_start_result
      {
        seq = 6l;
        reply_to = 5l;
        result = `Started (Bytes.of_string "request-id");
      };
    Request_dispatch
      {
        seq = 7l;
        request = Bytes.of_string "request-id";
        operation = "test.echo";
        payload = Bytes.of_string "42";
      };
    Request_dispatch_result { seq = 8l; reply_to = 7l; accepted = true };
    Request_resolve
      {
        seq = 9l;
        request = Bytes.of_string "request-id";
        payload = Bytes.of_string "42";
      };
    Request_resolve_result
      { seq = 10l; reply_to = 9l; result = `Identity `Accepted };
    Request_cancel { seq = 11l; request = Bytes.of_string "request-id" };
    Request_cancel_result
      { seq = 12l; reply_to = 11l; result = `Not_pending };
    Request_resolved
      {
        seq = 13l;
        request = Bytes.of_string "request-id";
        payload = Bytes.of_string "42";
      };
    Request_closed
      {
        seq = 14l;
        request = Bytes.of_string "request-id";
        reason = Eta_crux.Request.Session_closed;
      };
  ]

let check_format label (module Format : Eta_crux.Wire.FORMAT) =
  List.iteri
    (fun index expected ->
      let bytes = Format.encode expected in
      match Format.decode bytes with
      | Ok actual ->
          Alcotest.(check bool)
            (Printf.sprintf "%s frame %d" label index)
            true (actual = expected)
      | Error _ ->
          Alcotest.failf "%s frame %d did not decode" label index)
    frames

let test_json_round_trip () =
  (match
     Eta_crux.Failure.decode_portable
       (Eta_crux.Failure.encode_portable portable_failure)
   with
  | Ok decoded ->
      Alcotest.(check bool) "portable failure round trip" true
        (decoded = portable_failure)
  | Error message ->
      let encoded =
        Eta_crux.Failure.encode_portable portable_failure
      in
      Alcotest.failf "portable failure decode: %s (%s)" message
        (Bytes.to_seq encoded
        |> Seq.map (fun byte ->
               Printf.sprintf "%02x" (Char.code byte))
        |> List.of_seq |> String.concat ""));
  check_format "json" (module Eta_crux_json.Format)

let test_sexp_round_trip () =
  check_format "sexp" (module Eta_crux_sexp.Format)

let test_json_rejects_duplicate_field () =
  let malformed =
    Bytes.of_string
      {|{"seq":0,"seq":0,"tag":"request.cancel","request":"aA"}|}
  in
  match Eta_crux_json.Format.decode malformed with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "duplicate JSON field was accepted"

let test_exact_frame_boundary () =
  let output =
    Frame.Projection_deliver
      { seq = 0l; reason = `Advancement; content = Updates [] }
  in
  Alcotest.(check string) "JSON projection fields"
    {|{"seq":0,"tag":"projection.deliver","reason":"advancement","content":"updates","entries":[]}|}
    (Eta_crux_json.Format.encode output |> Bytes.to_string);
  Alcotest.(check string) "S-expression projection fields"
    "(0 projection.deliver advancement updates 0)"
    (Eta_crux_sexp.Format.encode output |> Bytes.to_string);
  let dispatch =
    Frame.Request_dispatch_result
      { seq = 0l; reply_to = 1l; accepted = true }
  in
  Alcotest.(check string) "JSON accepted boolean"
    {|{"seq":0,"tag":"request.dispatch_result","reply_to":1,"accepted":true}|}
    (Eta_crux_json.Format.encode dispatch |> Bytes.to_string);
  Alcotest.(check string) "S-expression accepted boolean"
    "(0 request.dispatch_result 1 true)"
    (Eta_crux_sexp.Format.encode dispatch |> Bytes.to_string);
  List.iter
    (fun (label, format, encoded) ->
      let module Format = (val format : Eta_crux.Wire.FORMAT) in
      match Format.decode (Bytes.of_string encoded) with
      | Error _ -> ()
      | Ok _ -> Alcotest.failf "%s accepted an out-of-range uint32" label)
    [
      ( "JSON sequence",
        (module Eta_crux_json.Format),
        {|{"seq":4294967296,"tag":"request.cancel","request":""}|} );
      ( "JSON reply",
        (module Eta_crux_json.Format),
        {|{"seq":0,"tag":"request.dispatch_result","reply_to":4294967296,"accepted":true}|}
      );
      ( "S-expression sequence",
        (module Eta_crux_sexp.Format),
        "(4294967296 request.cancel \"\")" );
      ( "S-expression reply",
        (module Eta_crux_sexp.Format),
        "(0 request.dispatch_result 4294967296 true)" );
    ]

let () =
  Alcotest.run "eta_crux wire"
    [
      ( "formats",
        [
          Alcotest.test_case "JSON round trip" `Quick test_json_round_trip;
          Alcotest.test_case "S-expression round trip" `Quick
            test_sexp_round_trip;
          Alcotest.test_case "JSON duplicate rejection" `Quick
            test_json_rejects_duplicate_field;
          Alcotest.test_case "exact frame boundary" `Quick
            test_exact_frame_boundary;
        ] );
    ]
